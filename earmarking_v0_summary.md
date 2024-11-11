### Earmarking Overview and Design Constraints

An important goal of this system is to manage and track **debt reduction** for users over time, based on :

1. Users **share of the total debt**
2. The **duration of time** their debt is held
3. **variable collateral request rate** (transmuter).

The system achieves this without:

1. **Storing every token request rate change**: We don’t want to keep a detailed history of each rate change, as this would consume significant storage and complicate calculations.
2. **Updating every user’s position** whenever there’s a global redemption or rate change: This approach would be inefficient and costly, particularly as the number of users increases.

Instead, the system uses **accumulated values** to handle debt reductions and rate changes in a scalable, on-demand way.

### Key Components

1. **Cumulative Tracking Variables**:

   - **`cumulativeCollateralRequested`**: Tracks the total amount of collateral requested across all blocks up to the last rate change. This variable aggregates the requested collateral over time, allowing the system to capture all past requests without storing individual rate change history.
   - **`cumulativeRedeemedCollateralPerDebt`**: Tracks the cumulative collateral redeemed per unit of debt. This value increases each time a global redemption is performed, proportionally reducing each user’s debt based on their share of the total debt.
   - **`collateralRequestRate`**: The current rate of tokens requested per block. This value can be updated through specific actions (like `deposit`, `withdraw` and `repay`), but it does not require historical storage for every rate change.

2. **User Information**:
   - Each user has a **`userDebt`** value, representing their current outstanding debt.
   - Each user also has a **`userLastRedeemDebtSnapshot`**, which stores the cumulative state of `cumulativeRedeemedCollateralPerDebt` at the time of their last interaction. This snapshot allows for **on-demand calculations** of redeemed collateral when the user’s position is queried or updated.

### Core Functions and Their Roles

1. **`deposit`(transmuter) , `withdraw`(transmuter) and `repay`(alchemist)**:
   - **`deposit`, `withdraw` and `repay`** are the only actions that update `collateralRequestRate`.
   - When either function is called, they first calculate the **cumulative collateral requested** since the last rate change using `cumulativeCollateralRequested` and add the new rate-adjusted request to it. This lets the system apply changes based on all previous rates without storing each one.
   - The `collateralRequestRate` is then updated to a new rate, and `lastRateUpdateBlock` is reset to the current block to mark the new rate’s start.
2. **`redeem` (Alchemist, Global Redemption)**:

   - The `redeem` function can be called by anyone to apply a global redemption. It calculates all cumulative collateral requested up to the current block based on `cumulativeCollateralRequested` and `collateralRequestRate`.
   - The system then proportionally reduces all debt by updating `cumulativeRedeemedCollateralPerDebt`, reflecting the total requested collateral across all users.
   - Since each user has a snapshot (`userLastRedeemDebtSnapshot`) of `cumulativeRedeemedCollateralPerDebt`, this update enables on-demand debt reduction for users when they query or interact with the system.

3. **`mint` (Alchemist)**:
   - When a user mints more debt, their individual debt increases. The `userLastRedeemDebtSnapshot` is also updated to align with the current `cumulativeRedeemedCollateralPerDebt`, ensuring any future redemptions only apply to the debt accumulated from this point onward.

### How Lazy Evaluation Achieves Scalability

Lazy evaluation allows the system to calculate **redeemed collateral and debt reductions on demand** only when a user queries or interacts with the system. Here’s how it works:

1. **Avoiding Real-Time Updates**: Rather than updating each user’s debt and collateral every time there’s a global redemption or rate change, the system defers these calculations. By using cumulative variables (`cumulativeRedeemedCollateralPerDebt` and `cumulativeCollateralRequested`), we capture the impact of all historical redemptions and rate changes without applying them in real-time.

2. **Using Snapshots for Accurate On-Demand Calculation**:
   - Each user’s **`userLastRedeemDebtSnapshot`** acts as a **reference point** for the last time their debt was affected by a redemption. When they query their position, the system calculates the **unaccounted redeemed collateral** by comparing the difference between the current `cumulativeRedeemedCollateralPerDebt` and the user’s `userLastRedeemDebtSnapshot`.
   - This difference represents the total redemption effect on their debt since their last interaction, ensuring that their debt is reduced accurately and proportionally to the time they’ve held it.

### How isuser debt actually reduced

The goal is to ensure that each user’s debt is reduced:

1. **Proportionally to Their Share of Total Debt**:

   - By using `cumulativeRedeemedCollateralPerDebt`, redemptions are applied uniformly across all users based on their debt share. When `redeem` is called, `cumulativeRedeemedCollateralPerDebt` is incremented by the redeemed collateral per unit of debt, making it scalable to all users.

2. **According to the Duration of Their Debt**:
   - Since each user’s debt reduction is calculated on-demand using snapshots (`userLastRedeemDebtSnapshot`), redemptions only apply to debt held since the last interaction. This approach ensures that users who hold debt for longer periods bear a greater share of redemptions, aligning with the time-based reduction goal.

### Example of Lazy Evaluation in Action

Suppose:

- `redeem` is called several times, incrementing `cumulativeRedeemedCollateralPerDebt` based on cumulative collateral requests.
- User A does not interact with the system until they query their position.
- When User A queries, the system calculates their unaccounted redeemed collateral by comparing `cumulativeRedeemedCollateralPerDebt` with their last snapshot (`userLastRedeemDebtSnapshot`).

This calculation applies all redemptions proportionally and retroactively based on how long User A’s debt has been active, even though they hadn’t interacted during those redemptions.

### Summary

This system achieves efficient, accurate, and scalable debt and collateral management by:

- **Tracking cumulative values** for collateral requests and redemptions.
- **Using snapshots** to defer calculations for each user until they interact with the system.
- **Reducing debt based on duration and debt share** without the need for historical storage or per-user updates.

Lazy evaluation and cumulative tracking allow this design to scale effectively, meeting the system’s constraints and achieving its debt reduction goals accurately. This setup is optimal for environments where token request rates and global redemptions change dynamically, but frequent, direct updates to user states would be costly and impractical.
