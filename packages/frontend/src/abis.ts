import { parseAbi } from "viem";

export const factoryAbi = parseAbi([
  "function createLaunch((string name,string symbol,string metadataURI,bytes32 metadataHash,uint256 minimumCreatorTokensOut,uint256 deadline) params) payable returns ((uint256 launchId,address creator,address token,address curve,address officialPair,address treasury,address graduationManager,bytes32 metadataHash,string metadataURI) record)",
  "function launchCount() view returns (uint256)",
]);

export const curveAbi = parseAbi([
  "function state() view returns (uint8)",
  "function virtualBaseReserve() view returns (uint256)",
  "function virtualTokenReserve() view returns (uint256)",
  "function realBaseReserve() view returns (uint256)",
  "function curveTokenInventory() view returns (uint256)",
  "function creatorTradingFees() view returns (uint256)",
  "function treasuryTradingFees() view returns (uint256)",
  "function claimableBaseOf(address) view returns (uint256)",
  "function claimableRefundOf(address) view returns (uint256)",
  "function buy(uint256 minimumTokensOut,uint256 deadline) payable returns (uint256 tokensOut)",
  "function sell(uint256 tokenAmount,uint256 minimumBaseOut,uint256 deadline) returns (uint256 netBaseCredit)",
  "function claimRefund() returns (uint256 amount)",
  "function claimBaseCredit() returns (uint256 amount)",
  "function claimCreatorFees() returns (uint256 amount)",
  "function claimTreasuryFees() returns (uint256 amount)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 amount) returns (bool)",
]);

export const routerAbi = parseAbi([
  "function getAmountsOut(uint256 amountIn,address[] path) view returns (uint256[] amounts)",
  "function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin,address[] path,address to,uint256 deadline) payable",
  "function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn,uint256 amountOutMin,address[] path,address to,uint256 deadline)",
]);
