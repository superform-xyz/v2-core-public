// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// external
import {ModuleKitHelpers, AccountInstance, UserOpData, PackedUserOperation} from "modulekit/ModuleKit.sol";
import {ExecutionLib} from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import {MODULE_TYPE_VALIDATOR} from "modulekit/accounts/kernel/types/Constants.sol";
import {ERC7579ValidatorBase} from "modulekit/Modules.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

// Superform
import {SuperMerkleValidator} from "../../../src/core/validators/SuperMerkleValidator.sol";
import {SuperValidatorBase} from "../../../src/core/validators/SuperValidatorBase.sol";
import {ISuperSignatureStorage} from "../../../src/core/interfaces/ISuperSignatureStorage.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleTreeHelper} from "../../utils/MerkleTreeHelper.sol";
import {RhinestoneModuleKit, ModuleKitHelpers, AccountInstance, UserOpData} from "modulekit/ModuleKit.sol";

// Helper contract to test transient sig storage
contract SignatureTransientTester {
    SuperMerkleValidator public validator;

    constructor(address _validator) {
        validator = SuperMerkleValidator(_validator);
    }

    function validateAndRetrieve(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        returns (bytes memory)
    {
        validator.validateUserOp(userOp, userOpHash);
        return validator.retrieveSignatureData(userOp.sender);
    }
}

contract SuperMerkleValidatorTest is MerkleTreeHelper, RhinestoneModuleKit {
    using ModuleKitHelpers for *;
    using ExecutionLib for *;

    IERC4626 public vaultInstance;
    AccountInstance public instance;
    address public account;

    SuperMerkleValidator public validator;
    bytes public validSigData;

    UserOpData approveUserOp;
    UserOpData transferUserOp;
    UserOpData depositUserOp;
    UserOpData withdrawUserOp;

    uint256 privateKey;
    address signerAddr;

    bytes4 constant VALID_SIGNATURE = bytes4(0x1626ba7e);

    function setUp() public {
        validator = new SuperMerkleValidator();

        (signerAddr, privateKey) = makeAddrAndKey("The signer");
        vm.label(signerAddr, "The signer");

        instance = makeAccountInstance(keccak256(abi.encode("TEST")));
        account = instance.account;

        instance.installModule({
            moduleTypeId: MODULE_TYPE_VALIDATOR,
            module: address(validator),
            data: abi.encode(address(signerAddr))
        });
        assertEq(validator.getAccountOwner(account), signerAddr);

        approveUserOp = _createDummyApproveUserOp();
        transferUserOp = _createDummyTransferUserOp();
        depositUserOp = _createDummyDepositUserOp();
        withdrawUserOp = _createDummyWithdrawUserOp();
    }

    function test_SourceValidator_IsModuleType() public view {
        assertTrue(validator.isModuleType(MODULE_TYPE_VALIDATOR));
        assertFalse(validator.isModuleType(1234));
    }

    function test_SourceValidator_OnInstall() public view {
        assertTrue(validator.isInitialized(account));
    }

    function test_SourceValidator_namespace() public view {
        assertEq(validator.namespace(), "SuperValidator");
    }

    function test_SourceValidator_GetAccountOwner() public view {
        assertEq(validator.getAccountOwner(account), address(signerAddr));
    }

    function test_SourceValidator_OnInstall_RevertIf_AlreadyInitialized() public {
        AccountInstance memory newInstance = makeAccountInstance(keccak256(abi.encode("TEST")));
        address newAccount = newInstance.account;

        vm.startPrank(newAccount);

        vm.expectRevert(SuperValidatorBase.ALREADY_INITIALIZED.selector);
        validator.onInstall("");
        vm.stopPrank();
    }

    function test_SourceValidator_OnUninstall() public {
        vm.startPrank(account);
        validator.onUninstall("");
        vm.stopPrank();

        assertFalse(validator.isInitialized(account));
    }

    function test_SourceValidator_OnUninstall_RevertIf_NotInitialized() public {
        vm.startPrank(makeAddr("account"));
        vm.expectRevert(ISuperSignatureStorage.NOT_INITIALIZED.selector);
        validator.onUninstall("");
        vm.stopPrank();
    }

    function test_Validate_isValidSignatureWithSender_NotInitialized() public {
        vm.startPrank(address(0x1));
        vm.expectRevert(ISuperSignatureStorage.NOT_INITIALIZED.selector);
        validator.isValidSignatureWithSender(account, bytes32(0), "");
        vm.stopPrank();
    }

    function test_Validate_isValidSignatureWithSender() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(root);
        bytes memory _validSigData = abi.encode(validUntil, root, proof[0], proof[0], signature);

        vm.prank(account);
        bytes4 result =
            validator.isValidSignatureWithSender(account, approveUserOp.userOpHash, abi.encode(_validSigData));

        assertEq(result, VALID_SIGNATURE);
    }

    function test_Validate_isValidSignatureWithSender_InvalidProof() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(root);
        bytes memory _validSigData = abi.encode(validUntil, root, proof, proof, signature);

        vm.startPrank(account);
        vm.expectRevert(SuperValidatorBase.INVALID_PROOF.selector);
        validator.isValidSignatureWithSender(account, approveUserOp.userOpHash, abi.encode(_validSigData));
        vm.stopPrank();
    }

    function test_Validate_isValidSignatureWithSender_InvalidSignature() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(bytes32(0));
        bytes memory _validSigData = abi.encode(validUntil, root, proof[0], proof[0], signature);

        vm.prank(account);
        bytes4 result =
            validator.isValidSignatureWithSender(account, approveUserOp.userOpHash, abi.encode(_validSigData));

        assertEq(result, bytes4(""));
    }

    function test_Dummy_1LeafMerkleTree() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256(bytes.concat(keccak256(abi.encode("leaf 0"))));

        bytes32 root = leaves[0];
        bytes32[] memory proof = new bytes32[](0);

        bool isValid = MerkleProof.verify(proof, root, leaves[0]);
        assertTrue(isValid, "Merkle proof for leaf 0 should be valid");
    }

    function test_ValidateUserOp_1LeafMerkleTree_NotInitialized() public {
        vm.startPrank(makeAddr("account"));
        vm.expectRevert();
        validator.validateUserOp(approveUserOp.userOp, approveUserOp.userOpHash);
        vm.stopPrank();
    }

    function test_ValidateUserOp_1LeafMerkleTree() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(root);

        // validate first user op
        _testUserOpValidation(validUntil, root, proof[0], signature, approveUserOp);

        bytes memory retrievedSig = validator.retrieveSignatureData(account);
        assertEq(retrievedSig, "");
    }

    function test_ValidateUserOp_RetrieveSignatureData() public {
        SignatureTransientTester tester = new SignatureTransientTester(address(validator));

        uint48 validUntil = uint48(block.timestamp + 1 hours);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);
        bytes memory signature = _getSignature(root);

        bytes32[] memory dstProofs = new bytes32[](1);
        dstProofs[0] = keccak256(abi.encode("PROOF"));
        bytes memory sigData = abi.encode(validUntil, root, proof[0], dstProofs, signature);
        approveUserOp.userOp.signature = sigData;

        bytes memory retrievedSig = tester.validateAndRetrieve(approveUserOp.userOp, approveUserOp.userOpHash);

        assertEq(retrievedSig, sigData, "Retrieved signature should match the provided signature");
    }

    function test_ValidateUserOp_1LeafMerkleTree_InvalidProof() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);
        bytes memory signature = _getSignature(root);
        bytes memory _validSigData = abi.encode(validUntil, root, proof, proof, signature);

        approveUserOp.userOp.signature = _validSigData;
        vm.expectRevert(SuperValidatorBase.INVALID_PROOF.selector);
        validator.validateUserOp(approveUserOp.userOp, approveUserOp.userOpHash);
    }

    function test_ValidateUserOp_1LeafMerkleTree_InvalidSignature() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);
        bytes memory signature = _getSignature(bytes32(0));
        bytes memory _validSigData = abi.encode(validUntil, root, proof[0], proof[0], signature);

        approveUserOp.userOp.signature = _validSigData;
        vm.prank(account);
        bytes4 result =
            validator.isValidSignatureWithSender(account, approveUserOp.userOpHash, abi.encode(_validSigData));
        assertNotEq(result, VALID_SIGNATURE);
    }

    function test_Dummy_OnChainMerkleTree() public pure {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256(bytes.concat(keccak256(abi.encode("leaf 0"))));
        leaves[1] = keccak256(bytes.concat(keccak256(abi.encode("leaf 1"))));
        leaves[2] = keccak256(bytes.concat(keccak256(abi.encode("leaf 2"))));
        leaves[3] = keccak256(bytes.concat(keccak256(abi.encode("leaf 3"))));

        bytes32[][] memory proof;
        bytes32 root;
        {
            bytes32[] memory level1 = new bytes32[](2);
            level1[0] = _hashPair(leaves[0], leaves[1]);
            level1[1] = _hashPair(leaves[2], leaves[3]);

            root = _hashPair(level1[0], level1[1]);

            proof = new bytes32[][](4);

            // Proof for leaves[0] - Sibling is leaves[1], Parent is level1[1]
            proof[0] = new bytes32[](2);
            proof[0][0] = leaves[1]; // Sibling of leaves[0]
            proof[0][1] = level1[1]; // Parent of leaves[0] and leaves[1]

            // Proof for leaves[1] - Sibling is leaves[0], Parent is level1[1]
            proof[1] = new bytes32[](2);
            proof[1][0] = leaves[0]; // Sibling of leaves[1]
            proof[1][1] = level1[1]; // Parent of leaves[0] and leaves[1]

            // Proof for leaves[2] - Sibling is leaves[3], Parent is level1[0]
            proof[2] = new bytes32[](2);
            proof[2][0] = leaves[3]; // Sibling of leaves[2]
            proof[2][1] = level1[0]; // Parent of leaves[2] and leaves[3]

            // Proof for leaves[3] - Sibling is leaves[2], Parent is level1[0]
            proof[3] = new bytes32[](2);
            proof[3][0] = leaves[2]; // Sibling of leaves[3]
            proof[3][1] = level1[0]; // Parent of leaves[2] and leaves[3]
        }

        bool isValid = MerkleProof.verify(proof[0], root, leaves[0]);
        assertTrue(isValid, "Merkle proof for leaf 0 should be valid");

        // check 2nd leaf
        isValid = MerkleProof.verify(proof[1], root, leaves[1]);
        assertTrue(isValid, "Merkle proof for leaf 1 should be valid");

        // check 3rd leaf
        isValid = MerkleProof.verify(proof[2], root, leaves[2]);
        assertTrue(isValid, "Merkle proof for leaf 2 should be valid");

        // check 4th leaf
        isValid = MerkleProof.verify(proof[3], root, leaves[3]);
        assertTrue(isValid, "Merkle proof for leaf 3 should be valid");
    }

    function test_Dummy_OnChainMerkleTree_WithActualUserOps() public view {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);
        leaves[1] = _createSourceValidatorLeaf(transferUserOp.userOpHash, validUntil);
        leaves[2] = _createSourceValidatorLeaf(depositUserOp.userOpHash, validUntil);
        leaves[3] = _createSourceValidatorLeaf(withdrawUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bool isValid = MerkleProof.verify(proof[0], root, leaves[0]);
        assertTrue(isValid, "Merkle proof should be valid");
    }

    function test_ValidateUserOp() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);
        leaves[1] = _createSourceValidatorLeaf(transferUserOp.userOpHash, validUntil);
        leaves[2] = _createSourceValidatorLeaf(depositUserOp.userOpHash, validUntil);
        leaves[3] = _createSourceValidatorLeaf(withdrawUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(root);

        // validate first user op
        _testUserOpValidation(validUntil, root, proof[0], signature, approveUserOp);

        // validate second user op
        _testUserOpValidation(validUntil, root, proof[1], signature, transferUserOp);

        // validate third user op
        _testUserOpValidation(validUntil, root, proof[2], signature, depositUserOp);

        // validate fourth user op
        _testUserOpValidation(validUntil, root, proof[3], signature, withdrawUserOp);
    }

    function test_ExpiredSignature() public {
        vm.warp(block.timestamp + 2 hours);

        uint48 validUntil = uint48(block.timestamp - 1 hours);

        // simulate a merkle tree with 4 leaves (4 user ops)
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);
        leaves[1] = _createSourceValidatorLeaf(transferUserOp.userOpHash, validUntil);
        leaves[2] = _createSourceValidatorLeaf(depositUserOp.userOpHash, validUntil);
        leaves[3] = _createSourceValidatorLeaf(withdrawUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        bytes memory signature = _getSignature(root);

        validSigData = abi.encode(validUntil, root, proof[0], proof[0], signature);

        approveUserOp.userOp.signature = validSigData;
        ERC7579ValidatorBase.ValidationData result =
            validator.validateUserOp(approveUserOp.userOp, approveUserOp.userOpHash);
        uint256 rawResult = ERC7579ValidatorBase.ValidationData.unwrap(result);
        bool _sigFailed = rawResult & 1 == 1;
        uint48 _validUntil = uint48(rawResult >> 160);

        assertTrue(_sigFailed, "Sig should fail");
        assertLt(_validUntil, block.timestamp, "Should not be valid");
    }

    function test_tamperingSignature_And_Proof_For_1LeafMerkleTree() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // simulate a merkle tree with 1 leaves
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _createSourceValidatorLeaf(approveUserOp.userOpHash, validUntil);

        (bytes32[][] memory proof, bytes32 root) = _createValidatorMerkleTree(leaves);

        assertEq(proof[0].length, 0, "Proof should be empty");
        assertEq(root, leaves[0], "Root should be the same as the leaf");

        bytes memory signature = _getSignature(root);

        // tamper the merkle root
        bytes32 _prevRoot = root;
        root = keccak256(abi.encode("tampered root"));
        validSigData = abi.encode(validUntil, root, proof, proof, signature);

        approveUserOp.userOp.signature = validSigData;

        vm.expectRevert(SuperValidatorBase.INVALID_PROOF.selector);
        validator.validateUserOp(approveUserOp.userOp, bytes32(0));

        // tamper the proof
        root = _prevRoot;
        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = keccak256(abi.encode("tampered proof"));
        validSigData = abi.encode(validUntil, root, _proof, _proof, signature);

        approveUserOp.userOp.signature = validSigData;

        vm.expectRevert(SuperValidatorBase.INVALID_PROOF.selector);
        validator.validateUserOp(approveUserOp.userOp, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIVATE METHODS
    //////////////////////////////////////////////////////////////*/
    function _getSignature(bytes32 root) private view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(validator.namespace(), root));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // test sig here; fail early if invalid
        address _expectedSigner = ECDSA.recover(ethSignedMessageHash, signature);
        assertEq(_expectedSigner, signerAddr, "Signature should be valid");
        return signature;
    }

    function _testUserOpValidation(
        uint48 validUntil,
        bytes32 root,
        bytes32[] memory proof,
        bytes memory signature,
        UserOpData memory userOpData
    ) private {
        validSigData = abi.encode(validUntil, root, proof, proof, signature);

        userOpData.userOp.signature = validSigData;
        ERC7579ValidatorBase.ValidationData result = validator.validateUserOp(userOpData.userOp, userOpData.userOpHash);
        uint256 rawResult = ERC7579ValidatorBase.ValidationData.unwrap(result);
        bool _sigFailed = rawResult & 1 == 1;
        uint48 _validUntil = uint48(rawResult >> 160);

        assertFalse(_sigFailed, "Sig should be valid");
        assertGt(_validUntil, block.timestamp, "validUntil should be valid");
    }

    function _createDummyApproveUserOp() private returns (UserOpData memory) {
        return instance.getExecOps(
            address(this),
            0,
            abi.encodeWithSelector(IERC20.approve.selector, address(this), 1e18),
            address(instance.defaultValidator)
        );
    }

    function _createDummyTransferUserOp() private returns (UserOpData memory) {
        return instance.getExecOps(
            address(this),
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, address(this), 1e18),
            address(instance.defaultValidator)
        );
    }

    function _createDummyDepositUserOp() private returns (UserOpData memory) {
        return instance.getExecOps(
            address(this),
            0,
            abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, address(this)),
            address(instance.defaultValidator)
        );
    }

    function _createDummyWithdrawUserOp() private returns (UserOpData memory) {
        return instance.getExecOps(
            address(this),
            0,
            abi.encodeWithSelector(IERC4626.withdraw.selector, 1e18, address(this)),
            address(instance.defaultValidator)
        );
    }
}
