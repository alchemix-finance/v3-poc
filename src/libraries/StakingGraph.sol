// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/* Block-granular stake progression tracking for the Transmuter implemented
 * as a double, delta Fenwick tree.  By tracking stake size and range, this
 * structure reports a block-granular report of the full amount of the stake
 * that can be redeemed in aggregate across all Transmuter stakes.
 *
 * For better gas effeciency, storage operations are halved by packing the
 * individual nodes of the two trees into a single 256-bit slot, utilizing
 * a 144/112 bit split.  The least significant portion storing the raw
 * amount, and the other storing the amount * block.  This 144/112 split
 * thus provides 32-bits for block numbers
 */

library StakingGraph {

    //112/144 bit split for delta and product storage, providing 32 bits for start/expiration
    uint256 private constant DELTA_BITS = 112;

    //Derive related constants from DELTA_BITS
    uint256 private constant DELTA_MASK = (2**DELTA_BITS)-1;
    uint256 private constant DELTA_SIGNBIT = 2**(DELTA_BITS-1);
    uint256 private constant PRODUCT_BITS = 256-DELTA_BITS;

    //MIN/MAX constants for DELTA and PRODUCT
    int256 private constant DELTA_MAX = int256(2**DELTA_BITS)-1;
    int256 private constant DELTA_MIN = -int256(2**DELTA_BITS);
    int256 private constant PRODUCT_MAX = int256(2**PRODUCT_BITS)-1;
    int256 private constant PRODUCT_MIN = -int256(2**PRODUCT_BITS);

    //Maximum graph size as per bit-split, 32-bit for 112 DELTA_BITS
    uint256 private constant GRAPH_MAX = 2**(PRODUCT_BITS-DELTA_BITS);

    //Structure containing full graph state
    struct Graph {
        uint256 size; //current tree size, power-of-two
        uint256[GRAPH_MAX + 1] g; //Fenwick trees are one-indexed, +1 to avoid array OOB revert
    }

    /**
     * Add/update a position in/to the graph
     * Revert if amount underflows or overflows, or if start/duration would exceed GRAPH_MAX
     *
     * @param g contract storage instance of a Graph struct
     * @param amount (DELTA_MIN >= amount >= DELTA_MAX)
     * @param start  block where the stake change begins
     * @param duration total range of the stake change
     */
    function addStake(Graph storage g, int256 amount, uint256 start, uint256 duration) internal {
        unchecked {
            require(amount <= DELTA_MAX && amount >= DELTA_MIN);
            require(start < GRAPH_MAX-1);

            uint256 expiration = start + duration;
            require(expiration < GRAPH_MAX-1);

            uint256 graphSize = g.size;
            
            //check if the tree must be expanded

            uint256 newSize = expiration + 2;
            if (newSize >= graphSize) {
                //round expiration up to the next power of 2
                newSize |= newSize >> 1;
                newSize |= newSize >> 2;
                newSize |= newSize >> 4;
                newSize |= newSize >> 8;
                newSize |= newSize >> 16;
                if (GRAPH_MAX > 2**32) {//handle GRAPH_MAX > 32-bit
                    newSize |= newSize >> 32;
                    newSize |= newSize >> 64;
                    newSize |= newSize >> 128;
                }
                newSize++;

                //DEBUG: uncomment for maximum tree size
                //newSize = GRAPH_MAX;

                require (newSize <= GRAPH_MAX);

                if (graphSize != 0) {
                    //if the graph isn't null, copy the last entry up to the new end
                    uint256 copy = g.g[graphSize];
                    while (graphSize <= newSize) {
                        g.g[graphSize] = copy;
                        graphSize += graphSize;
                    }
                }
                graphSize = newSize;
                g.size = newSize;
            }

            //update tree storage with deltas, revert if results cannot be packed into storage
            update(g.g, start + 1, graphSize, amount, amount * int256(start));
            update(g.g, expiration + 1, graphSize, -amount, -amount * int256(expiration));
        }
    }

    /**
     * Query the new amount that is earmarked between blocks start and end
     * Revert if start or end exceed GRAPH_MAX
     *
     * @param g contract storage instance of a Graph struct
     * @param start block at the start of the query range
     * @param end block at end of the query range
     */
    function queryStake(Graph storage g, uint256 start, uint256 end) internal view returns (int256) {
        int256 begDelta;
        int256 begProd;
        int256 endDelta;
        int256 endProd;
        unchecked {
            require (end <= GRAPH_MAX); //catch overflow

            start--;
            require (start <= GRAPH_MAX); //catch overflow and underflow

            (begDelta,begProd) = query(g.g, start);
            (endDelta,endProd) = query(g.g, end);

            return ((int256(end) * endDelta) - endProd) - ((int256(start) * begDelta) - begProd);
        }
    }

    /**
     * Update the packed fenwick tree with delta & deltaProd.  Extend the tree if possible/necessary
     * Revert if the partial sums cannot be packed back into the structure
     *
     * For internal use within the library for index validation
     */
    function update(uint256[GRAPH_MAX + 1] storage graph, uint256 index, uint256 treeSize, int256 delta, int256 deltaProd) private {
        unchecked {
            index += 1;
            while (index <= treeSize) {
                //graph[index] += delta on 2 packed values
                uint256 packed = graph[index];
                int256 ad;
                int256 ap;

                //unpack values
                if ((packed&DELTA_SIGNBIT) != 0) {
                    ad = int256(packed | ~DELTA_MASK); //extend set sign bit
                } else {
                    ad = int256(packed & DELTA_MASK); //extend zero sign bit
                }
                ap = int256(packed)>>DELTA_BITS; //automatic sign extension

                ad+=delta;
                ap+=deltaProd;

                //pack and store new values
                require(ad <= DELTA_MAX && ad >= DELTA_MIN);
                require(ap <= PRODUCT_MAX && ap >= PRODUCT_MIN);
                graph[index] = (uint256(ad)&DELTA_MASK)|uint256(ap<<DELTA_BITS);

                assembly {
                    index := add(index, and(index, sub(0, index)))
                }
            }
        }
    }

    /**
     * Retrieve a pair of values at the given point index within the packed fenwick tree
     * No reverts, as the sum of 256 144-bit values cannot overflow int256
     *
     * For internal use within the library for index validation
     */
     function query(uint256[GRAPH_MAX + 1] storage graph, uint256 index) private view returns (int256 sum, int256 sumProd) {
        unchecked {
            index += 1;
            while (index > 0) {
                //sum += graph[index] on 2 packed values
                uint256 packed = graph[index];
                int256 ad;
                int256 ap;

                //unpack values
                if ((packed&(2**(DELTA_BITS-1))) != 0) {
                    ad = int256(packed | ~DELTA_MASK); //extend set sign bit
                } else {
                    ad = int256(packed & DELTA_MASK); //extend zero sign bit
                }
                ap = int256(packed)>>DELTA_BITS; //automatic sign extension

                sum += ad;
                sumProd += ap;

                assembly {
                    index := sub(index, and(index, sub(0, index)))
                }
            }
        }
    }
}