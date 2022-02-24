
pragma solidity 0.8.5;


interface IPinkAntiBot {
    function setTokenOwner(address owner) external;
  
    function onPreTransferCheck(
      address from,
      address to,
      uint256 amount
    ) external;
  }