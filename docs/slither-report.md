# Slither report

Static analysis of the contracts in `contracts/src` with Slither.

| | |
|---|---|
| Date | 2026-11-06 |
| Slither | 0.11.6 |
| Compiler | solc 0.8.30, optimizer 200 runs, EVM version cancun |
| Foundry | 1.9.0 |
| Command | `slither .` run in `contracts/` (see the README) |
| Analysed | 18 contracts (6 of ours, 12 from OpenZeppelin), 102 detectors |

## Result

18 results from 3 detectors. All are informational and all are in OpenZeppelin's
library code. **No detector reports anything in the six contracts written for this
project.**

| Detector | Severity | Results | Where | Decision |
|----------|----------|--------:|-------|----------|
| `assembly` | informational | 13 | `SafeERC20`, `StorageSlot` (OpenZeppelin) | accepted: audited library code, not ours to change |
| `pragma` | informational | 1 | OpenZeppelin files use ranges such as `^0.8.20`; ours use exactly `0.8.30` | accepted: `foundry.toml` pins solc 0.8.30, so everything is compiled with one version |
| `solc-version` | informational | 4 | the version ranges in OpenZeppelin's files allow old compilers with known bugs | accepted: same reason, the pinned compiler is the only one used |

Nothing had to be fixed in the contracts.

## What a clean result does and does not show

Before trusting "no findings" we checked that Slither can see a bug in this code. We
planted one in a scratch copy of `RequesterApproveEscrow.approve` (never committed):
the token transfer was moved before the state write and `nonReentrant` was removed.

| Planted bug | Slither |
|-------------|---------|
| transfer made with `token.transfer(...)` | reported: `reentrancy-no-eth`, `reentrancy-events`, `unchecked-transfer` |
| transfer made with `token.safeTransfer(...)`, as in the real code | **not reported** |

So Slither analyses our contracts, but its re-entrancy detectors do not see the token
calls. The reason is that `SafeERC20` in OpenZeppelin 5.7 makes the call in inline
assembly, which Slither does not follow. The clean result is therefore no evidence
about re-entrancy. That is covered in three other ways:

- every function writes the new state and emits its events before it calls the token;
- every function that pays out is `nonReentrant`;
- `contracts/test/Reentrancy.t.sol` attacks the escrow with a token that calls back
  during a payout. The test passes on the real code, fails on the planted bug, and
  passes again when only `nonReentrant` is restored.

## Raw output

```
INFO:Detectors:
Detector: assembly
SafeERC20.tryGetDecimals(IERC20) (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#169-177) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#171-176)
SafeERC20._safeTransfer(IERC20,address,uint256,bool) (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#188-212) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#191-211)
SafeERC20._safeTransferFrom(IERC20,address,address,uint256,bool) (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#224-256) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#233-255)
SafeERC20._safeApprove(IERC20,address,uint256,bool) (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#267-291) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#270-290)
StorageSlot.getAddressSlot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#66-70) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#67-69)
StorageSlot.getBooleanSlot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#75-79) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#76-78)
StorageSlot.getBytes32Slot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#84-88) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#85-87)
StorageSlot.getUint256Slot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#93-97) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#94-96)
StorageSlot.getInt256Slot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#102-106) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#103-105)
StorageSlot.getStringSlot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#111-115) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#112-114)
StorageSlot.getStringSlot(string) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#120-124) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#121-123)
StorageSlot.getBytesSlot(bytes32) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#129-133) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#130-132)
StorageSlot.getBytesSlot(bytes) (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#138-142) uses assembly
	- INLINE ASM (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#139-141)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#assembly-usage
INFO:Detectors:
Detector: pragma
5 different versions of Solidity are used:
	- Version constraint >=0.6.2 is used by:
		->=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC1363.sol#4)
		->=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC20Metadata.sol#4)
		->=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/extensions/IERC20Metadata.sol#4)
	- Version constraint >=0.4.16 is used by:
		->=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC165.sol#4)
		->=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC20.sol#4)
		->=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/IERC20.sol#4)
		->=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/utils/introspection/IERC165.sol#4)
	- Version constraint >=0.8.4 is used by:
		->=0.8.4 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/draft-IERC6093.sol#4)
	- Version constraint ^0.8.20 is used by:
		-^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/ERC20.sol#4)
		-^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#4)
		-^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/Context.sol#4)
		-^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/ReentrancyGuard.sol#4)
		-^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#5)
	- Version constraint 0.8.30 is used by:
		-0.8.30 (src/BudgetGuard.sol#2)
		-0.8.30 (src/EscrowBase.sol#2)
		-0.8.30 (src/MockUSD.sol#2)
		-0.8.30 (src/OptimisticStakeEscrow.sol#2)
		-0.8.30 (src/RequesterApproveEscrow.sol#2)
		-0.8.30 (src/VerifierAttestedEscrow.sol#2)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#different-pragma-directives-are-used
INFO:Detectors:
Detector: solc-version
Version constraint >=0.6.2 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- MissingSideEffectsOnSelectorAccess
	- AbiReencodingHeadOverflowWithStaticArrayCleanup
	- DirtyBytesArrayToStorage
	- NestedCalldataArrayAbiReencodingSizeValidation
	- ABIDecodeTwoDimensionalArrayMemory
	- KeccakCaching
	- EmptyByteArrayCopy
	- DynamicArrayCleanup
	- MissingEscapingInFormatting
	- ArraySliceDynamicallyEncodedBaseType
	- ImplicitConstructorCallvalueCheck
	- TupleAssignmentMultiStackSlotComponents
	- MemoryArrayCreationOverflow.
It is used by:
	- >=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC1363.sol#4)
	- >=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC20Metadata.sol#4)
	- >=0.6.2 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/extensions/IERC20Metadata.sol#4)
Version constraint >=0.4.16 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- DirtyBytesArrayToStorage
	- ABIDecodeTwoDimensionalArrayMemory
	- KeccakCaching
	- EmptyByteArrayCopy
	- DynamicArrayCleanup
	- ImplicitConstructorCallvalueCheck
	- TupleAssignmentMultiStackSlotComponents
	- MemoryArrayCreationOverflow
	- privateCanBeOverridden
	- SignedArrayStorageCopy
	- ABIEncoderV2StorageArrayWithMultiSlotElement
	- DynamicConstructorArgumentsClippedABIV2
	- UninitializedFunctionPointerInConstructor_0.4.x
	- IncorrectEventSignatureInLibraries_0.4.x
	- ExpExponentCleanup
	- NestedArrayFunctionCallDecoder
	- ZeroFunctionSelector.
It is used by:
	- >=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC165.sol#4)
	- >=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/IERC20.sol#4)
	- >=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/IERC20.sol#4)
	- >=0.4.16 (dependencies/@openzeppelin-contracts-5.7.0/utils/introspection/IERC165.sol#4)
Version constraint >=0.8.4 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess
	- AbiReencodingHeadOverflowWithStaticArrayCleanup
	- DirtyBytesArrayToStorage
	- DataLocationChangeInInternalOverride
	- NestedCalldataArrayAbiReencodingSizeValidation
	- SignedImmutables.
It is used by:
	- >=0.8.4 (dependencies/@openzeppelin-contracts-5.7.0/interfaces/draft-IERC6093.sol#4)
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- ^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/ERC20.sol#4)
	- ^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/token/ERC20/utils/SafeERC20.sol#4)
	- ^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/Context.sol#4)
	- ^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/ReentrancyGuard.sol#4)
	- ^0.8.20 (dependencies/@openzeppelin-contracts-5.7.0/utils/StorageSlot.sol#5)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#incorrect-versions-of-solidity
INFO:Slither:. analyzed (18 contracts with 102 detectors), 18 result(s) found
```
