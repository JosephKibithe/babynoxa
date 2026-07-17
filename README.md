BabyNoxa is a token-launch lifecycle system with three major phases:

1. A creator submits verified project metadata.
2. Users trade against a bonding curve until its 800-million-token inventory is sold.
3. The project graduates into a V2-style liquidity pool and its LP position is permanently burned.

The explanation below describes the educational/local design. Real-value deployment would require professional auditing and adult-led legal review.

## Complete system flow

```mermaid
flowchart TD
    A["Creator submits metadata"] --> B["Backend validates image and links"]
    B --> C["Metadata URI and hash created"]
    C --> D["Factory creates token and curve"]
    D --> E["Creator optional initial purchase ≤ 2%"]
    E --> F["Bonding-curve trading"]
    F --> G{"Curve inventory sold?"}
    G -- "No" --> F
    G -- "Yes" --> H["Trading stops and graduation executes atomically"]
    H --> I["GraduationManagerV1 allocates 10% to treasury"]
    I --> J["Price-matched token amount calculated"]
    J --> K["Remaining reserve and matched tokens enter V2-style pool"]
    K --> L["100% of received LP burned"]
    L --> M["Normal AMM trading; no BabyNoxa fee"]
```

# 1. Participants

## Creator

The address that creates a project.

The creator:

- Provides token metadata.
- May make an optional initial purchase.
- Cannot initially purchase more than 2% of supply.
- Receives 50% of bonding-curve trading fees.
- Receives no free token allocation.
- Receives no fee after graduation.

## Trader

A user who buys or sells during the bonding-curve phase.

During local development, Anvil accounts represent traders.

## BabyNoxa treasury

Receives:

- 50% of the 1% curve-trading fee.
- The 10% graduation allocation.

It receives no LP under Graduation Manager V1.

## Keeper

Graduation is atomic under Graduation Manager V1, so no separate keeper call or keeper reimbursement is required.

# 2. Main components

| Component          | Responsibility                                    |
| ------------------ | ------------------------------------------------- |
| Metadata service   | Validates images, names, symbols and social links |
| Factory            | Creates and registers launches                    |
| Token              | Represents the fixed one-billion supply           |
| Bonding curve      | Handles pre-graduation price calculations         |
| Fee accounting     | Separates creator, treasury and reserve amounts   |
| Graduation manager | Converts a completed curve into liquidity         |
| Treasury vault     | Holds claimable BabyNoxa fees                     |
| Indexer            | Reads events for charts and activity              |
| Backend            | Search, metadata, moderation and indexing         |
| Frontend           | Creation, discovery, trading and project display  |

# 3. Metadata preparation

Metadata must be verified before launch creation.

The creator submits:

```text
name
symbol
description
image
website
Twitter/X
Telegram
Discord, optional
```

## Image validation

The backend should:

1. Check the real file type from its bytes.
2. Accept PNG, JPEG or WebP.
3. Fully decode the image.
4. Reject corrupted images.
5. Remove EXIF and location data.
6. Resize oversized images.
7. Convert the result to WebP.
8. Enforce the processed size limit.
9. Calculate the image hash.
10. Store the image.
11. Retrieve it again.
12. Compare the retrieved hash.

## Metadata validation

Recommended limits:

```text
Name:         1–32 characters
Symbol:       2–10 uppercase letters/numbers
Description:  Maximum 500 characters
Website:      HTTPS
Image:        Required
Schema:       Versioned
```

After validation, the backend creates canonical JSON:

```json
{
  "schemaVersion": 1,
  "name": "Example",
  "symbol": "EXAMPLE",
  "description": "An educational launch.",
  "image": "ipfs://image-cid",
  "website": "https://example.com",
  "twitter": "https://x.com/example",
  "telegram": "https://t.me/example"
}
```

It then calculates:

```text
metadata URI
metadata hash
image hash
```

The factory stores the URI and hash so a frontend can detect altered metadata.

## Immutable metadata

These should not change after launch:

- Name
- Symbol
- Image
- Description
- Creator
- Original metadata hash

Social links could be updated through separate versioned metadata records.

# 4. Project creation

The creator calls the factory with:

```text
verified metadata URI
metadata hash
token name
token symbol
optional initial purchase
```

The factory:

1. Validates that required fields exist.
2. Assigns a unique launch ID.
3. Creates or registers the fixed-supply token.
4. Creates the project’s curve.
5. Records the creator.
6. Snapshots the active graduation manager.
7. Starts the lifecycle in `Trading`.
8. Executes the optional initial creator purchase.

## Token rules

Confirmed rules:

- Total supply: 1 billion.
- Decimals: 18.
- No additional minting.
- No transfer tax.
- No blacklist.
- No arbitrary balance modification.
- No creator free allocation.
- No owner-controlled pausing after launch.

## Creator initial purchase

Maximum initial output:

[
1{,}000{,}000{,}000 \times 2%
=============================

20{,}000{,}000
]

The limit applies only to the purchase inside the creation transaction.

After launch, the creator address follows the same token rules as everyone else. There is no permanent maximum-wallet restriction.

# 5. Bonding-curve price

BabyNoxa uses a virtual-reserve constant-product model:

[
x \times y = k
]

Where:

- (x) is the virtual base-currency reserve.
- (y) is the virtual token reserve.
- (k) is the constant product.

The virtual reserves establish an initial price even though the curve begins with no real deposits.

Approximate spot price:

[
P = \frac{x}{y}
]

When users buy:

- The base reserve increases.
- The virtual token reserve decreases.
- The token price increases.

When users sell:

- The virtual token reserve increases.
- The base reserve decreases.
- The token price decreases.

Every calculation must round in the direction that preserves solvency:

[
x_{\text{new}} \times y_{\text{new}} \geq k
]

# 6. Buy lifecycle

A buy conceptually receives:

```text
buyer
input amount
minimum tokens expected
deadline
```

The intended processing order is:

1. Confirm the project is in `Trading`.
2. Confirm the input is greater than zero.
3. Confirm the deadline has not expired.
4. Calculate the 1% fee.
5. Divide the fee 50/50.
6. Use the remaining 99% as curve input.
7. Calculate tokens out.
8. Verify tokens out meets the user’s minimum.
9. Update curve reserves.
10. Transfer or record tokens for the buyer.
11. Update fee accounting.
12. Check graduation progress.
13. Emit a buy event.

## Fee example

For a mock input of `1 ETH`:

```text
Total input:       1.000 ETH
Trading fee:       0.010 ETH
Creator portion:   0.005 ETH
Treasury portion:  0.005 ETH
Curve input:       0.990 ETH
```

The trading fees are not part of the graduation reserve.

# 7. Sell lifecycle

A sell conceptually receives:

```text
seller
token amount
minimum output expected
deadline
```

Processing order:

1. Confirm state is `Trading`.
2. Confirm the seller has enough tokens.
3. Calculate gross curve output.
4. Confirm the curve has sufficient real reserves.
5. Calculate the 1% fee.
6. Divide the fee 50/50.
7. Verify net output meets the user’s minimum.
8. Update reserves.
9. Return tokens to curve inventory.
10. Record or transfer output to the seller.
11. Update fee accounting.
12. Emit a sell event.

Example:

```text
Gross sell output:  1.000 ETH
Trading fee:         0.010 ETH
Creator portion:     0.005 ETH
Treasury portion:    0.005 ETH
Seller receives:     0.990 ETH
```

# 8. Separate accounting

BabyNoxa must never treat the entire contract balance as curve liquidity.

Conceptually:

```text
Contract balance
├── Real curve reserves
├── Creator trading fees
├── Treasury trading fees
├── Graduation treasury allocation
└── Pending mock refunds
```

The relationship should always be testable:

```text
accounted balance
=
curve reserve
+ creator fees
+ treasury fees
+ refunds
```

Creator and treasury fees use pull accounting:

```text
claimableCreatorFees[creator]
claimableTreasuryFees
```

Trades should not send fees directly to their recipients because a failing recipient could block every trade.

# 9. Graduation threshold

Graduation occurs when the curve's real 800-million-token inventory is exhausted. Tokens returned by sells replenish that inventory, so historical gross sales cannot trigger graduation by themselves.

The confirmed V1 virtual reserves are:

```text
Initial virtual base reserve:    1.425 ETH
Initial virtual token reserve:   1,066,666,667 tokens
Real curve token inventory:        800,000,000 tokens
Terminal virtual token reserve:    266,666,667 tokens, approximately
```

Exhausting the real curve inventory implies:

```text
Terminal virtual base reserve: approximately 5.70 ETH
Net real base reserve:          approximately 4.275 ETH
```

The real base value is a derived result, not an independent graduation condition. Buys increase it, sells decrease it and curve-trading fees never enter it.

# 10. Threshold-crossing purchase

Suppose the curve requires another `0.05 ETH`, but the final buyer submits `0.20 ETH`.

The curve should:

1. Calculate only the amount required to complete the curve.
2. Execute that portion.
3. Charge fees only on the executed portion.
4. Record or return the excess.
5. Exhaust the remaining curve inventory.
6. Enter `GraduationReady` and execute V1 graduation atomically.
7. Finish in `Graduated`, permanently closing curve trading.

This prevents the final buyer from overpaying.

# 11. Automatic graduation

Graduation uses one atomic transaction. The final buy exhausts the curve inventory, temporarily enters `GraduationReady`, executes Graduation Manager V1 and finishes in `Graduated`.

If liquidity creation or LP burning fails, the entire final purchase reverts. No partial graduation state is retained, and the buyer can retry. Because there is no separate keeper transaction, V1 keeper reimbursement is zero.

# 12. GraduationManagerV1

The factory records the graduation-manager version when the token launches:

```text
Launch A → GraduationManagerV1 forever
Launch B → GraduationManagerV1 forever

Future V2 activated

Launch C → GraduationManagerV2
```

Existing projects cannot be moved to a different manager.

## V1 graduation calculation

At the expected terminal reserve:

```text
Graduation reserve:       approximately 4.2750 ETH
Graduation allocation:    approximately 0.4275 ETH (10%)
Liquidity reserve:        approximately 3.8475 ETH (90%)
```

The 10% allocation goes to the BabyNoxa treasury.
Keeper reimbursement is zero under atomic V1 graduation.

# 13. Price continuity

The first AMM price should approximately equal the curve’s final price.

Terminal curve price:

[
P_{\text{curve}} =
\frac{x_{\text{terminal}}}{y_{\text{terminal}}}
]

Required liquidity tokens:

[
T_{\text{liquidity}} =
\frac{E_{\text{liquidity}}}{P_{\text{curve}}}
]

Where:

- (E\_{\text{liquidity}}) is the remaining 90% reserve.
- (T\_{\text{liquidity}}) is the token amount paired with it.

Without this calibration, there could be an immediate price gap between the curve and the AMM.

Any token allocation not required for liquidity should be permanently burned rather than given to the creator or treasury.

BabyNoxa reserves 200 million real tokens for graduation. With approximately 3.8475 ETH entering liquidity, price continuity requires approximately 180 million tokens. The exact amount is calculated from terminal reserves using integer-safe rounding; the unused remainder, approximately 20 million tokens, is permanently burned.

# 14. LP policy

Graduation Manager V1 uses:

```text
Burned LP:   100%
Treasury LP: 0%
Creator LP:  0%
```

The token burn and LP-token burn are distinct:

```text
Graduation token reserve:  200,000,000 tokens
Tokens paired:             approximately 180,000,000
Unused tokens burned:      approximately 20,000,000
LP tokens burned:          100% of LP tokens received
```

All received LP is sent to the conventional dead address:

```text
0x000000000000000000000000000000000000dEaD
```

A future manager could implement a different policy, but only for launches created under that new version.

# 15. After graduation

After V1 graduation:

- Curve trading remains closed.
- The project trades through the AMM.
- BabyNoxa collects no additional trading fee.
- Creator collects no additional trading fee.
- The token remains tax-free.
- Initial LP cannot be withdrawn.
- Frontend changes from curve mode to AMM mode.

# 16. Events and indexing

Important conceptual events:

```text
LaunchCreated
MetadataCommitted
TokensPurchased
TokensSold
CreatorFeeAccrued
TreasuryFeeAccrued
GraduationReady
GraduationExecuted
LiquidityCreated
LiquidityBurned
```

The backend indexer reads these events to build:

- Activity history
- Price charts
- Volume
- Creator pages
- Graduation progress
- Holder displays
- Trending lists

Events are historical records. Contract state remains the source of truth for current balances and lifecycle status.

# 17. Backend responsibilities

The backend manages:

- Metadata
- Images
- Search
- Comments
- Moderation
- Charts
- Event indexing
- Trending calculations
- Audit logs

It must not control:

- User balances
- Curve reserves
- Token supply
- Fee ownership
- Graduation state

# 18. Frontend responsibilities

Main pages:

```text
/                 Project discovery
/create           Creation form
/token/:id        Project and trading page
/portfolio        User activity and balances
/admin            Moderation
```

The project page displays:

- Verified metadata
- Creator
- Current lifecycle state
- Curve progress
- Price
- Mock reserve
- Trade history
- Creator holdings
- Graduation-manager version
- LP policy

# 19. Essential invariants

Your Foundry invariant tests should eventually prove:

1. Supply never exceeds one billion.
2. Creator initial purchase never exceeds 20 million.
3. Curve reserves never become negative.
4. Curve inventory never becomes negative.
5. Constant product never decreases unexpectedly.
6. Fees never count as graduation reserves.
7. User cannot sell more than their balance.
8. Curve trading stops when its real token inventory is exhausted.
9. Graduation can execute only once.
10. Atomic V1 graduation pays no keeper reimbursement.
11. Failure during atomic graduation reverts the entire final purchase.
12. Graduation Manager V1 gives treasury zero LP.
13. Graduation Manager V1 burns all received LP.
14. Existing launches cannot change manager versions.
15. Metadata hashes cannot be silently replaced.
16. The initial AMM price matches the terminal curve price within the approved rounding tolerance.
17. Graduation tokens not required for price-matched liquidity are burned.

# 20. Decisions still pending

## Confirmed V1 economic parameters

```text
Total supply:                 1,000,000,000 tokens
Minting after creation:       disabled
Token taxes:                  none
Real curve allocation:        800,000,000 tokens
Initial virtual base:         1.425 ETH
Initial virtual tokens:       1,066,666,667 tokens
Graduation trigger:           curve inventory exhausted
Expected net base reserve:    approximately 4.275 ETH
Graduation token reserve:     200,000,000 tokens
Tokens paired:                price-matched amount, approximately 180,000,000
Unused graduation tokens:     permanently burned
Graduation allocation:        10% of curve reserve
Keeper reimbursement:         zero under atomic V1 graduation
V1 LP-token policy:           100% burned
Post-graduation fee:           none
```

The following implementation details still require simulation or policy decisions:

- Exact integer-rounding tolerance for curve-to-AMM price continuity
- Minimum trade size and dust policy
- Maximum transaction size or price-impact policy, if any
- Image size and storage provider
- Social-link update rules
- Moderation and reporting policy

The economic simulator must verify the confirmed parameters under normal, boundary and adversarial trade sequences before they are embedded in a stateful curve.
