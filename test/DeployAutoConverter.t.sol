// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import "../script/Deploy.s.sol";
import "../script/DeployAutoConverter.s.sol";

contract TestDeployAutoConverter is Script, Test {
    using stdJson for string;
    using stdStorage for StdStorage;

    uint256 optimismFork;
    /// @dev set OPTIMISM_RPC_URL in .env to run mainnet tests
    string OPTIMISM_RPC_URL = vm.envString("OPTIMISM_RPC_URL");
    /// @dev optionally set FORK_BLOCK_NUMBER in .env / test set up for faster tests / fixed tests
    uint256 BLOCK_NUMBER = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
    string public CONSTANTS_FILENAME = vm.envString("CONSTANTS_FILENAME");
    string public jsonConstants;
    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public testDeployer = vm.rememberKey(deployPrivateKey);

    // address public constant testDeployer = /* address(1) */;

    address router;
    address USDC;
    address voter;

    Deploy deploy;
    DeployAutoConverter deployAutoConverter;

    constructor() {}

    function setUp() public {
        if (BLOCK_NUMBER != 0) {
            optimismFork = vm.createFork(OPTIMISM_RPC_URL, BLOCK_NUMBER);
        } else {
            optimismFork = vm.createFork(OPTIMISM_RPC_URL);
        }
        vm.selectFork(optimismFork);

        deploy = new Deploy();
        deployAutoConverter = new DeployAutoConverter();

        // load in variables
        string memory root = vm.projectRoot();
        string memory basePath = string.concat(root, "/script/constants/");
        string memory path = string.concat(basePath, CONSTANTS_FILENAME);
        jsonConstants = vm.readFile(path);
        USDC = abi.decode(jsonConstants.parseRaw(".USDC"), (address));
        router = abi.decode(jsonConstants.parseRaw(".v2.Router"), (address));
        voter = abi.decode(jsonConstants.parseRaw(".v2.Voter"), (address));

        // use test account for deployment
        stdstore.target(address(deploy)).sig("deployerAddress()").checked_write(testDeployer);
        stdstore.target(address(deployAutoConverter)).sig("deployerAddress()").checked_write(testDeployer);
    }

    function testLoadedState() public {
        assertTrue(router != address(0));
        assertTrue(USDC != address(0));
        assertTrue(voter != address(0));
    }

    function testDeployScript() public {
        deploy.run();
        deployAutoConverter.run();

        assertTrue(address(deployAutoConverter.autoConverterFactory()) != address(0));

        // AutoConverterFactory state checks
        assertEq(deployAutoConverter.autoConverterFactory().voter(), voter);
        assertEq(deployAutoConverter.autoConverterFactory().router(), router);

        assertEq(address(deployAutoConverter.keeperRegistry().owner()), testDeployer);
        assertTrue(
            deployAutoConverter.relayFactoryRegistry().isApproved(address(deployAutoConverter.autoConverterFactory()))
        );
    }
}
