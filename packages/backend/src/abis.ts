export const canonicalEventAbis = [
  "event LaunchCreated(uint256 indexed launchId,address indexed creator,address indexed token,address curve,address officialPair,address treasury,address graduationManager)",
  "event MetadataCommitted(uint256 indexed launchId,address indexed token,bytes32 indexed metadataHash,string metadataURI)",
  "event TokensPurchased(address indexed buyer,uint256 grossBaseSubmitted,uint256 grossBaseExecuted,uint256 netBaseToCurve,uint256 tokensOut,uint256 creatorFee,uint256 treasuryFee,uint256 grossBaseRefund)",
  "event TokensSold(address indexed seller,uint256 tokensIn,uint256 grossBaseOut,uint256 netBaseCredit,uint256 creatorFee,uint256 treasuryFee)",
  "event CreatorFeeAccrued(address indexed beneficiary,address indexed trader,uint256 amount,bool isBuy)",
  "event TreasuryFeeAccrued(address indexed beneficiary,address indexed trader,uint256 amount,bool isBuy)",
  "event GraduationReady(address indexed token,address indexed graduationManager,uint256 realBaseReserve,uint256 graduationTokenReserve)",
  "event RefundAccrued(address indexed buyer,uint256 amount)",
  "event SellCreditAccrued(address indexed seller,uint256 amount)",
  "event EtherClaimed(address indexed beneficiary,address indexed recipient,uint256 amount,bytes32 indexed claimType)",
  "event LaunchEtherClaimed(uint256 indexed launchId,address indexed beneficiary,address indexed recipient,bytes32 claimType,uint256 amount)",
  "event GraduationExecuted(address indexed token,address indexed curve,address indexed officialPair,uint256 treasuryAllocation,uint256 liquidityBase,uint256 liquidityTokens,uint256 burnedTokens)",
  "event LiquidityCreated(address indexed token,address indexed officialPair,uint256 baseAmount,uint256 tokenAmount,uint256 liquidity)",
  "event LiquidityBurned(address indexed token,address indexed officialPair,address indexed burnAddress,uint256 liquidity)",
  "event GraduationTokensBurned(address indexed token,address indexed curve,uint256 amount)",
  "event UnsolicitedAssetSentToBurn(address indexed asset,uint256 amount)",
  "event Transfer(address indexed from,address indexed to,uint256 value)",
  // Canonical Uniswap V2 pair swap, emitted by the official pair after graduation so
  // post-graduation buys/sells are indexed alongside the pre-graduation curve trades.
  "event Swap(address indexed sender,uint256 amount0In,uint256 amount1In,uint256 amount0Out,uint256 amount1Out,address indexed to)",
] as const;
