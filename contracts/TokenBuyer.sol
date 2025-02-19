pragma solidity ^0.8.20;

import "./interfaces/ITokenBuyer.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/IWETH.sol";
import "./libraries/UniswapV2Library.sol";

contract TokenBuyer is OwnableUpgradeable {
    uint16 public constant PERCENT_DENOMINATOR = 10_000;

    address public v2Factory;

    address public tokenToBuy;
    address public intermediaryToken;
    address public tokenToSell;

    // this pairs need for TokenToSale -> WETH -> TokenToBuy
    address public pairTokenToSellIntermediary;
    address public pairIntermediaryTokenToBuy;
    // this pair for direct pair: TokenToSale -> TokenToBuy
    address public pairToSellToBuy;

    uint16 public slippage;

    error WrongTokenError();
    error TokenZeroAddressError();

    event TokenPurchase(address indexed who, uint256 bnbIn, uint256 ufiOut);

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    function initialize(address factory) public initializer {
        v2Factory = factory;
        __Ownable_init(_msgSender());
        __tokenBuyer_init_unchained(100);
    }

    function __tokenBuyer_init_unchained(uint16 _slippage) internal initializer {
        slippage = _slippage;
    }

    function setPair() external onlyOwner {
        if (tokenToBuy == address(0) || tokenToSell == address(0) || intermediaryToken == address(0)) {
            revert TokenZeroAddressError();
        }

        pairTokenToSellIntermediary = pairFor(tokenToSell, intermediaryToken);
        pairIntermediaryTokenToBuy = pairFor(intermediaryToken, tokenToBuy);
        pairToSellToBuy = pairFor(tokenToSell, tokenToBuy);
    }

    function setTokenToBuy(address newTokenToBuy) external onlyOwner {
        tokenToBuy = newTokenToBuy;
    }

    function setTokenToSell(address newTokenToSell) external onlyOwner {
        tokenToSell = newTokenToSell;
    }

    function setIntermediaryToken(address newIntermediaryToken) external onlyOwner {
        intermediaryToken = newIntermediaryToken;
    }

    function changeSlippage(uint16 _slippage) public onlyOwner {
        require(_slippage <= PERCENT_DENOMINATOR, "Slippage too high");
        slippage = _slippage;
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'PancakeLibrary: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'PancakeLibrary: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint(keccak256(abi.encodePacked(
            hex'ff',
            v2Factory,
            keccak256(abi.encodePacked(token0, token1)),
            //if it is a pancake swap factory - we need to change initCodeHash
            //if it is not - use uniswap v2 official init code hash
            v2Factory == 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73 ?
                hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5' // init code hash for Pancake Swap
                : hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'   // init code hash for Uniswap V2
        )))));
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address pair, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pair).getReserves();
        (reserveA, reserveB) = tokenA == IUniswapV2Pair(pair).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address pair, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'TokenBuyer: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        (uint reserveIn, uint reserveOut) = getReserves(pair, path[0], path[1]);
        amounts[1] = UniswapV2Library.getAmountOut(amounts[0], reserveIn, reserveOut);
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address pair, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'TokenBuyer: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;

        (uint reserveIn, uint reserveOut) = getReserves(pair, path[0], path[1]);
        amounts[0] = UniswapV2Library.getAmountIn(amounts[1], reserveIn, reserveOut);

    }

    function stableToUFI(uint256 _amountBUSD) external view returns (uint256, uint256) {
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairTokenToSellIntermediary).getReserves();
        (uint256 reserveTokenToSell, uint256 reserveIntermediary) = tokenToSell == IUniswapV2Pair(pairTokenToSellIntermediary).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 amountOutIntermediary = UniswapV2Library.getAmountOut(_amountBUSD, reserveTokenToSell, reserveIntermediary);

        (reserve0, reserve1,) = IUniswapV2Pair(pairIntermediaryTokenToBuy).getReserves();
        (uint256 reserveTokenToBuy, uint256 reserveIntermediaryToBuy) = tokenToBuy == IUniswapV2Pair(pairIntermediaryTokenToBuy).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 amountOutToBuy = UniswapV2Library.getAmountOut(amountOutIntermediary, reserveIntermediaryToBuy, reserveTokenToBuy);

        return (amountOutIntermediary, amountOutToBuy);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address pair, address _to) internal virtual {
        (uint amount0Out, uint amount1Out) = tokenToSell == IUniswapV2Pair(pair).token0() || (intermediaryToken == IUniswapV2Pair(pair).token0() && pair == pairIntermediaryTokenToBuy) ? (uint(0), amounts[1]) : (amounts[1], uint(0));
        IUniswapV2Pair(pair).swap(
            amount0Out, amount1Out, _to, new bytes(0)
        );

    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address pair,
        address to,
        address[] memory path,
        uint deadline
    ) internal virtual ensure(deadline) returns (uint[] memory amounts) {
        amounts = getAmountsOut(pair, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'TokenBuyer: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, pair, amounts[0]
        );
        _swap(amounts, pair, to);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] memory path,
        address to,
        address pair,
        uint deadline
    ) internal virtual ensure(deadline) returns (uint[] memory amounts) {
        amounts = getAmountsIn(pair, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, pair, amounts[0]
        );
        _swap(amounts, pair, to);
    }

    function swapExactToSellToBuy(uint amountIn, address to, uint deadline) external {
        uint256 tokenExpected;
        {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairTokenToSellIntermediary).getReserves();
            tokenExpected = IUniswapV2Pair(pairTokenToSellIntermediary).token0() == intermediaryToken ? UniswapV2Library.getAmountOut(amountIn, reserve0, reserve1) : UniswapV2Library.getAmountOut(amountIn, reserve1, reserve0);
        }

        uint256 minTokenExpected = tokenExpected * (PERCENT_DENOMINATOR - slippage) / PERCENT_DENOMINATOR;

        address[] memory pathToSell = new address[](2);
        pathToSell[0] = tokenToSell;
        pathToSell[1] = intermediaryToken;
        //toSell -> intermediaryToken
        uint[] memory amounts = swapExactTokensForTokens(amountIn, minTokenExpected, pairTokenToSellIntermediary, to, pathToSell, deadline);

        {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairIntermediaryTokenToBuy).getReserves();
            tokenExpected = IUniswapV2Pair(pairIntermediaryTokenToBuy).token0() == intermediaryToken ? UniswapV2Library.getAmountOut(amounts[1], reserve0, reserve1) : UniswapV2Library.getAmountOut(amounts[1], reserve1, reserve0);
        }

        minTokenExpected = tokenExpected * (PERCENT_DENOMINATOR - slippage) / PERCENT_DENOMINATOR;
        //intermediaryToken -> toBuy
        address[] memory pathToBuy = new address[](2);
        pathToBuy[0] = intermediaryToken;
        pathToBuy[1] = tokenToBuy;
        swapExactTokensForTokens(amounts[1], tokenExpected, pairIntermediaryTokenToBuy, to, pathToBuy, deadline);
    }

    function swapToSellExactToBuy(uint amountOut, address to, uint deadline) external {
        uint256 tokenExpected;
        {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairTokenToSellIntermediary).getReserves();
            tokenExpected = IUniswapV2Pair(pairTokenToSellIntermediary).token0() == intermediaryToken ? UniswapV2Library.getAmountIn(amountOut, reserve0, reserve1) : UniswapV2Library.getAmountIn(amountOut, reserve1, reserve0);
        }

        uint256 minTokenExpected = tokenExpected * (PERCENT_DENOMINATOR - slippage) / PERCENT_DENOMINATOR;
        //toSell -> intermediaryToken
        address[] memory pathToSell = new address[](2);
        pathToSell[0] = tokenToSell;
        pathToSell[1] = intermediaryToken;
        uint[] memory amounts = swapTokensForExactTokens(amountOut, amountOut * (PERCENT_DENOMINATOR - slippage) / PERCENT_DENOMINATOR, pathToSell, to, pairTokenToSellIntermediary, deadline);
        //intermediaryToken -> toBuy
        address[] memory pathToBuy = new address[](2);
        pathToBuy[0] = intermediaryToken;
        pathToBuy[1] = tokenToBuy;
        {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairIntermediaryTokenToBuy).getReserves();
            tokenExpected = IUniswapV2Pair(pairIntermediaryTokenToBuy).token0() == intermediaryToken ? UniswapV2Library.getAmountOut(amounts[1], reserve0, reserve1) : UniswapV2Library.getAmountOut(amounts[1], reserve1, reserve0);
        }

        uint256 maxTokenExpected = tokenExpected * (PERCENT_DENOMINATOR - slippage) / PERCENT_DENOMINATOR;

        swapTokensForExactTokens(amounts[1], maxTokenExpected, pathToBuy, to, pairIntermediaryTokenToBuy, deadline);
    }


}