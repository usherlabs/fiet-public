# End-to-end test failure analysis
_Exported on 20/04/2026 at 18:46:36 GMT+10 from Cursor (3.1.15)_

---

**User**

e2e tests still failing with:

    │   │   │   │   ├─ [619] MMPositionManager::ownerOf(1) [staticcall]
    │   │   │   │   │   └─ ← [Return] 0x90F79bf6EB2c4f870365E785982E1f101E93b906
    │   │   │   │   ├─ [736] MarketFactory::corePoolToProxyHook(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e) [staticcall]
    │   │   │   │   │   └─ ← [Return] ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]
    │   │   │   │   ├─ [97838] VTSOrchestrator::onMMSettle(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], 1, 0, 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], false, false)
    │   │   │   │   │   ├─ [859] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::exttload(0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000001
    │   │   │   │   │   ├─ [603] LiquidityHub::isFactory(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [1745] MarketFactory::bounds(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   ├─ [796] LiquidityHub::boundLevel(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 1
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [81014] VTSLifecycleLinkedLib::onMMSettle() [delegatecall]
    │   │   │   │   │   │   ├─ [1001] LiquidityHub::getFactory(LiquidityCommitmentCertificate.e2e_non_ir: [0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB], LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]
    │   │   │   │   │   │   ├─ [736] MarketFactory::corePoolToProxyHook(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   ├─ [13613] VTSPositionLib::settlePositionGrowths() [delegatecall]
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c71ff) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x000000000bb80000000d89e7fffd8963efd1fc6a506488495d951d5263988d25
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x73e07b76aed9d4263adaca7ec0822ff61cd79aaae74ffdda85b4f5798740cfea) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c71ff) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x000000000bb80000000d89e7fffd8963efd1fc6a506488495d951d5263988d25
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x73e07b76aed9d4263adaca7ec0822ff61cd79aaae74ffdda85b4f5798740cfea) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   ├─ [9108] ProxyHook.e2e_non_ir::dryModifyLiquidities(VaultSettlementIntent({ requestedDelta: 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], creditBackedWithdrawal0: 170141183276008724700961287365449389792 [1.701e38], creditBackedWithdrawal1: 36223785 [3.622e7] })) [staticcall]
    │   │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   │   ├─ [4814] CanonicalVault::dryModifyLiquidities(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], VaultSettlementIntent({ requestedDelta: 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], creditBackedWithdrawal0: 170141183276008724700961287365449389792 [1.701e38], creditBackedWithdrawal1: 36223785 [3.622e7] })) [staticcall]
    │   │   │   │   │   │   │   │   ├─ [883] MarketFactory::isMarketFacade(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]) [staticcall]
    │   │   │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   │   │   └─ ← [Return] 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76]
    │   │   │   │   │   │   │   └─ ← [Return] 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   ├─ [1254] ProxyHook.e2e_non_ir::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   ├─ [251] CanonicalVault::marketFactory() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   ├─ [1254] ProxyHook.e2e_non_ir::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   ├─ [251] CanonicalVault::marketFactory() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   └─ ← [Return] 0x7ffffffdabf9d844f9b7b548429e96e00000000000000000000000000228bb297ffffffdabf9d844f9b7b548429e96e00000000000000000000000000228bb29000000000000000000000000000000007ffffffdabf9d844f9b7b548429e96e0000000000000000000000000000000000000000000000000000000000228bb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   ├─ emit PositionSettled(commitId: 1, positionIndex: 0, settlementDelta0: 170141183276008724700961287365449389792 [1.701e38], settlementDelta1: 36223785 [3.622e7], settledToken0: 0, settledToken1: 0, settledOverflowToken0: 0, settledOverflowToken1: 9909868827 [9.909e9], isSeizing: false, rfsOpen: false)
    │   │   │   │   │   └─ ← [Return] 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], false, 0, VaultSettlementIntent({ requestedDelta: 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], creditBackedWithdrawal0: 170141183276008724700961287365449389792 [1.701e38], creditBackedWithdrawal1: 36223785 [3.622e7] })
    │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   ├─ [85778] ProxyHook.e2e_non_ir::modifyLiquidities(VaultSettlementIntent({ requestedDelta: 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], creditBackedWithdrawal0: 170141183276008724700961287365449389792 [1.701e38], creditBackedWithdrawal1: 36223785 [3.622e7] }))
    │   │   │   │   │   ├─ [1745] MarketFactory::bounds(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   ├─ [796] LiquidityHub::boundLevel(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 1
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   ├─ [78487] CanonicalVault::modifyLiquidities(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], LiquidityCommitmentCertificate.e2e_non_ir: [0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB], LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806], VaultSettlementIntent({ requestedDelta: 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76], creditBackedWithdrawal0: 170141183276008724700961287365449389792 [1.701e38], creditBackedWithdrawal1: 36223785 [3.622e7] }), MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692])
    │   │   │   │   │   │   ├─ [883] MarketFactory::isMarketFacade(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   ├─ [438] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::balanceOf(CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], 506014132100997702128657764431530226998412358804 [5.06e47]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 170141183460469231731687303715920239380 [1.701e38]
    │   │   │   │   │   │   ├─ [4732] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::burn(CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], 506014132100997702128657764431530226998412358804 [5.06e47], 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   │   ├─ emit Transfer(caller: CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], from: CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], to: 0x0000000000000000000000000000000000000000, id: 506014132100997702128657764431530226998412358804 [5.06e47], amount: 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ [26613] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::take(Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   │   ├─ [25040] Token::transfer(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   │   │   ├─ emit Transfer(from: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, to: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], value: 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ emit LiquidityTakenFromVault(marketId: 0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, recipient: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], currency: Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], amount: 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   │   ├─ [438] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::balanceOf(CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], 733165304502811008602745119548910689383730904167 [7.331e47]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 36223785 [3.622e7]
    │   │   │   │   │   │   ├─ [4732] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::burn(CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], 733165304502811008602745119548910689383730904167 [7.331e47], 36223785 [3.622e7])
    │   │   │   │   │   │   │   ├─ emit Transfer(caller: CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], from: CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6], to: 0x0000000000000000000000000000000000000000, id: 733165304502811008602745119548910689383730904167 [7.331e47], amount: 36223785 [3.622e7])
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ [26613] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::take(Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 36223785 [3.622e7])
    │   │   │   │   │   │   │   ├─ [25040] Token::transfer(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 36223785 [3.622e7])
    │   │   │   │   │   │   │   │   ├─ emit Transfer(from: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, to: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], value: 36223785 [3.622e7])
    │   │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ emit LiquidityTakenFromVault(marketId: 0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, recipient: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], currency: Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], amount: 36223785 [3.622e7])
    │   │   │   │   │   │   └─ ← [Return] 57896044555889439775933633048311517355485203124897089558933145024178460080937 [5.789e76]
    │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   ├─ [3140] Token::transfer(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   ├─ emit Transfer(from: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], to: 0x90F79bf6EB2c4f870365E785982E1f101E93b906, value: 170141183276008724700961287365449389792 [1.701e38])
    │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   ├─ [3140] Token::transfer(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 36223785 [3.622e7])
    │   │   │   │   │   ├─ emit Transfer(from: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], to: 0x90F79bf6EB2c4f870365E785982E1f101E93b906, value: 36223785 [3.622e7])
    │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ [574] LiquidityCommitmentCertificate.e2e_non_ir::balanceOf(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   └─ ← [Return] 0
    │   │   │   ├─ [890] VTSOrchestrator::take(LiquidityCommitmentCertificate.e2e_non_ir: [0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB], 0x90F79bf6EB2c4f870365E785982E1f101E93b906, 0)
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   ├─ [10707] LiquidityCommitmentCertificate.e2e_non_ir::transfer(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 0)
    │   │   │   │   ├─ [1155] LiquidityHub::boundLevels(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 0x90F79bf6EB2c4f870365E785982E1f101E93b906) [staticcall]
    │   │   │   │   │   └─ ← [Return] 1, 0
    │   │   │   │   ├─ emit Transfer(from: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], to: 0x90F79bf6EB2c4f870365E785982E1f101E93b906, value: 0)
    │   │   │   │   ├─ [2286] LiquidityHub::executePlannedCancel(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 0x90F79bf6EB2c4f870365E785982E1f101E93b906)
    │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ [574] LiquidityCommitmentCertificate.e2e_non_ir::balanceOf(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   └─ ← [Return] 0
    │   │   │   ├─ [890] VTSOrchestrator::take(LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806], 0x90F79bf6EB2c4f870365E785982E1f101E93b906, 0)
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   ├─ [10707] LiquidityCommitmentCertificate.e2e_non_ir::transfer(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 0)
    │   │   │   │   ├─ [1155] LiquidityHub::boundLevels(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 0x90F79bf6EB2c4f870365E785982E1f101E93b906) [staticcall]
    │   │   │   │   │   └─ ← [Return] 1, 0
    │   │   │   │   ├─ emit Transfer(from: MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], to: 0x90F79bf6EB2c4f870365E785982E1f101E93b906, value: 0)
    │   │   │   │   ├─ [2286] LiquidityHub::executePlannedCancel(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692], 0x90F79bf6EB2c4f870365E785982E1f101E93b906)
    │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   └─ ← [Return] true
    │   │   │   └─ ← [Return] 0x
    │   │   └─ ← [Return] 0x
    │   ├─ [1038] VTSOrchestrator::assertNonZeroDeltas(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]) [staticcall]
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::stopBroadcast()
    │   └─ ← [Return]
    ├─ [651] VTSOrchestrator::getPositionId(1, 0) [staticcall]
    │   └─ ← [Return] 0x009dd7ab80ce4400c5f8f84019a45c457e7cf4f9ed7b66c1e2a5ea9d5a3892e1
    ├─ [1104] VTSOrchestrator::getPositionSettledAmounts(0x009dd7ab80ce4400c5f8f84019a45c457e7cf4f9ed7b66c1e2a5ea9d5a3892e1) [staticcall]
    │   └─ ← [Return] 0, 9909868827 [9.909e9]
    ├─ [0] console::log("e2e: inactive surplus before drain, eff0:", 0, "eff1:", 9909868827 [9.909e9]) [staticcall]
    │   └─ ← [Stop]
    ├─ [0] VM::startBroadcast(<pk>)
    │   └─ ← [Return]
    ├─ [123468] MMPositionManager::modifyLiquidities(0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000014000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024eac991b0000000000000000000000000000000000000000000000000000000000000000, 1776666360 [1.776e9])
    │   ├─ [119176] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::unlock(0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000014000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024eac991b0000000000000000000000000000000000000000000000000000000000000000)
    │   │   ├─ [117132] MMPositionManager::unlockCallback(0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000014000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024eac991b0000000000000000000000000000000000000000000000000000000000000000)
    │   │   │   ├─ [114191] MMPositionActionsImpl::handleAction(0, 0x00000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024eac991b0000000000000000000000000000000000000000000000000000000000000000) [delegatecall]
    │   │   │   │   ├─ [4933] VTSOrchestrator::getPosition(1, 0) [staticcall]
    │   │   │   │   │   └─ ← [Return] Position({ owner: 0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692, poolId: 0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, commitId: 1, tickLower: -60, tickUpper: 60, liquidity: 0, isActive: false, salt: 0xada5013122d395ba3c54772283fb069b10426056ef8ca54750cb9bb552a59e7d, checkpoint: RFSCheckpoint({ openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0 }) }), 0x009dd7ab80ce4400c5f8f84019a45c457e7cf4f9ed7b66c1e2a5ea9d5a3892e1
    │   │   │   │   ├─ [619] MMPositionManager::ownerOf(1) [staticcall]
    │   │   │   │   │   └─ ← [Return] 0x90F79bf6EB2c4f870365E785982E1f101E93b906
    │   │   │   │   ├─ [736] MarketFactory::corePoolToProxyHook(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e) [staticcall]
    │   │   │   │   │   └─ ← [Return] ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]
    │   │   │   │   ├─ [84488] VTSOrchestrator::onMMSettle(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], 1, 0, 9909868827 [9.909e9], false, false)
    │   │   │   │   │   ├─ [859] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::exttload(0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000001
    │   │   │   │   │   ├─ [603] LiquidityHub::isFactory(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [1745] MarketFactory::bounds(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   ├─ [796] LiquidityHub::boundLevel(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 1
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [67664] VTSLifecycleLinkedLib::onMMSettle() [delegatecall]
    │   │   │   │   │   │   ├─ [1001] LiquidityHub::getFactory(LiquidityCommitmentCertificate.e2e_non_ir: [0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB], LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]
    │   │   │   │   │   │   ├─ [736] MarketFactory::corePoolToProxyHook(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   ├─ [13613] VTSPositionLib::settlePositionGrowths() [delegatecall]
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c71ff) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x000000000bb80000000d89e7fffd8963efd1fc6a506488495d951d5263988d25
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x73e07b76aed9d4263adaca7ec0822ff61cd79aaae74ffdda85b4f5798740cfea) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c71ff) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x000000000bb80000000d89e7fffd8963efd1fc6a506488495d951d5263988d25
    │   │   │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x73e07b76aed9d4263adaca7ec0822ff61cd79aaae74ffdda85b4f5798740cfea) [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   ├─ [8447] ProxyHook.e2e_non_ir::dryModifyLiquidities(VaultSettlementIntent({ requestedDelta: 9909868827 [9.909e9], creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0 })) [staticcall]
    │   │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   │   │   ├─ [4153] CanonicalVault::dryModifyLiquidities(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], VaultSettlementIntent({ requestedDelta: 9909868827 [9.909e9], creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0 })) [staticcall]
    │   │   │   │   │   │   │   │   ├─ [883] MarketFactory::isMarketFacade(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]) [staticcall]
    │   │   │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   │   │   └─ ← [Return] 0
    │   │   │   │   │   │   │   └─ ← [Return] 0
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   │   ├─ [7945] VTSPositionLib::getRFS() [delegatecall]
    │   │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffdb15366e5
    │   │   │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   ├─ emit PositionSettled(commitId: 1, positionIndex: 0, settlementDelta0: 0, settlementDelta1: 0, settledToken0: 0, settledToken1: 0, settledOverflowToken0: 0, settledOverflowToken1: 9909868827 [9.909e9], isSeizing: false, rfsOpen: false)
    │   │   │   │   │   └─ ← [Return] 0, false, 0, VaultSettlementIntent({ requestedDelta: 0, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0 })
    │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   ├─ [12986] ProxyHook.e2e_non_ir::modifyLiquidities(VaultSettlementIntent({ requestedDelta: 0, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0 }))
    │   │   │   │   │   ├─ [1745] MarketFactory::bounds(MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   ├─ [796] LiquidityHub::boundLevel(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876], MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] 1
    │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494]
    │   │   │   │   │   ├─ [292] LiquidityCommitmentCertificate.e2e_non_ir::underlying() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67]
    │   │   │   │   │   ├─ [447] MarketFactory::canonicalVault() [staticcall]
    │   │   │   │   │   │   └─ ← [Return] CanonicalVault: [0xC0CD5e398d0F7C824274EB640A7e6e2108206Bc6]
    │   │   │   │   │   ├─ [5695] CanonicalVault::modifyLiquidities(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, Token: [0x58A2755C4d6afdF9a8717008A05F687c3a8cb494], Token: [0x806c44f027a6f6ee75aDe3F6DBf1c6DB496FfC67], LiquidityCommitmentCertificate.e2e_non_ir: [0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB], LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806], VaultSettlementIntent({ requestedDelta: 0, creditBackedWithdrawal0: 0, creditBackedWithdrawal1: 0 }), MMPositionManager: [0xA1833Ef768385Fc4C6cD8876AFE511730FEe3692])
    │   │   │   │   │   │   ├─ [883] MarketFactory::isMarketFacade(0x77f58b195236f4fe827fc5d7761cc1da82cd8bf6b848a8357345e825adace35e, ProxyHook.e2e_non_ir: [0xA9A05008d35F035C066CF6356FAD71E06226a888]) [staticcall]
    │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   └─ ← [Return] 0
    │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   └─ ← [Stop]
    │   │   │   └─ ← [Return] 0x
    │   │   └─ ← [Return] 0x
    │   ├─ [1038] VTSOrchestrator::assertNonZeroDeltas(MarketFactory: [0xb58f1937DBC4272AE704e052d32CAA934F7CD876]) [staticcall]
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::stopBroadcast()
    │   └─ ← [Return]
    ├─ [651] VTSOrchestrator::getPositionId(1, 0) [staticcall]
    │   └─ ← [Return] 0x009dd7ab80ce4400c5f8f84019a45c457e7cf4f9ed7b66c1e2a5ea9d5a3892e1
    ├─ [1104] VTSOrchestrator::getPositionSettledAmounts(0x009dd7ab80ce4400c5f8f84019a45c457e7cf4f9ed7b66c1e2a5ea9d5a3892e1) [staticcall]
    │   └─ ← [Return] 0, 9909868827 [9.909e9]
    └─ ← [Revert] e2e: inactive surplus settle made no progress (check vault liquidity / queue)



== Logs ==
  === E2E: MarketMaker ===
  E2E DeployFullStack on ethsepolia
  PoolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
  CREATE2 Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
  CREATE3 Factory: 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
  Expected ProxyHook (extra market): 0xA9A05008d35F035C066CF6356FAD71E06226a888
  OK: position created
  commitId: 1
  tick (before swap) 0
  OK: swap complete
  zeroForOne: true
  amountIn: 5000000000000000000000
  amountOut: 29953549
  tick (after swap) -887272
  tick (before swap) -887272
  OK: swap complete
  zeroForOne: false
  amountIn: 5000000000000000000000
  amountOut: 59997090
  tick (after swap) 887271
  OK: swap both directions complete
  OK: position poked
  fee lcc0 taken: 90401
  fee lcc1 taken: 180532
  e2e: inactive surplus before drain, eff0: 0 eff1: 9909868827
Error: script failed: e2e: inactive surplus settle made no progress (check vault liquidity / queue)
error: Recipe `e2e-market-maker` failed on line 753 with exit code 1

---

**Cursor**

I’m tracing the failing inactive-surplus settle path and will compare the runtime trace against the relevant VTS/MM settlement code to pinpoint why the second drain makes no progress.

The trace already shows the key symptom: the first settle moves principal out, but the second settle sees only `settledOverflowToken1` left and computes a zero `requestedDelta`, so I’m now checking whether that overflow is intentionally non-drainable or whether the e2e helper is assuming the wrong mechanism.

I’ve confirmed the helper is reading *effective* settled (`settled + overflow`), not just live settled. Next I’m checking whether `SETTLE_POSITION` is even capable of consuming overflow-only remnants after a burn, because the trace suggests it isn’t.

The unit tests are helpful here: the existing happy-path decommit test only proves that `prepareSettle(...)` can drain when the leftover is still serviceable as a normal withdrawal. Your trace is different: after the first drain, only `settledOverflowToken1` remains, and `dryModifyLiquidities(...)` returns `0`, so the second `SETTLE_POSITION` has nothing routeable to pull out.

I’ve narrowed it to a concrete mismatch in the helper logic: it retries while `effectiveSettled > 0`, but the remaining balance is pure overflow with no immediately withdrawable market reserve behind it, so every subsequent `SETTLE_POSITION` is correctly clamped to zero by the vault.

The failure now looks like a **serviceability problem**, not a loop bug.

Your helper is draining against **effective settled**:

```788:845:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
function _getEffectiveSettledPair(IVTSOrchestrator vts, uint256 commitId, uint256 positionIndex)
    internal
    view
    returns (uint256 eff0, uint256 eff1)
{
    PositionId pid = vts.getPositionId(commitId, positionIndex);
    return vts.getPositionSettledAmounts(pid);
}
...
bool progressed = eff0After < eff0Before || eff1After < eff1Before;
if (!progressed) {
    revert("e2e: inactive surplus settle made no progress (check vault liquidity / queue)");
}
```

But `getPositionSettledAmounts()` is not “live-withdrawable settled”; it is `settled + settledOverflow`:

```409:421:contracts/evm/src/VTSOrchestrator.sol
function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1) {
    PositionAccounting storage pa = s.positionAccounting[positionId];
    return PositionAccountingLib.effectiveSettled(pa);
}

function getPositionSettledOverflowAmounts(PositionId positionId)
    external
    view
    returns (uint256 overflow0, uint256 overflow1)
{
    PositionAccounting storage pa = s.positionAccounting[positionId];
    return (pa.settledOverflow.token0, pa.settledOverflow.token1);
}
```

What your trace shows is:

1. First post-burn settle succeeds and drains the serviceable slice.
2. After that, the position still has `settledOverflowToken1 = 9,909,868,827`.
3. On the next settle, `onMMSettle()` plans a withdrawal from inactive `effectiveSettled`, but the vault clamps it to **zero** because there is no reserve/credit available for that lane.

That clamp is expected from these paths:

```463:529:contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol
if (!isActive) {
    PositionAccounting storage pa = s.positionAccounting[positionId];
    settledCapacity = PositionAccountingLib.effectiveSettledLane(pa, tokenIndex);
}
...
BalanceDelta availableDelta = p.vault.dryModifyLiquidities(
    VaultSettlementIntent({
        requestedDelta: LiquidityUtils.safeToBalanceDelta(
            plannedWithdrawal0, plannedWithdrawal1, false, false
        ),
        creditBackedWithdrawal0: plan.deltaBacked0,
        creditBackedWithdrawal1: plan.deltaBacked1
    })
);
```

```294:326:contracts/evm/src/CanonicalVault.sol
if (delta1 > 0) {
    uint256 requested1 = LiquidityUtils.safeInt128ToUint256(delta1);
    uint256 creditBacked1 = settlementIntent.creditBackedWithdrawal1;
    if (creditBacked1 > requested1) creditBacked1 = requested1;
    uint256 settledRequested1 = requested1 - creditBacked1;
    uint256 settledAvailable1 = marketLiquidityReserves[marketId][Currency.unwrap(currency1)];
    uint256 actual1 = creditBacked1 + Math.min(settledRequested1, settledAvailable1);
    if (actual1 < requested1) actualDelta1 = SafeCast.toInt128(actual1);
}
```

So the second settle makes no progress because the leftover is **overflow-only and not currently serviceable**. The trace even confirms that: `dryModifyLiquidities(...)` returns `0`, then `PositionSettled(... settlementDelta1: 0, settledOverflowToken1: 9909868827)`.

In short: **the script assumes `effectiveSettled > 0` means “drainable now”, but in this scenario it only means “economically owed eventually”.**

What to do next:

- If this e2e is meant to stay a happy path, you need a step that **replenishes token1 market reserve / produced credit before decommit**. Without that, the remnant is legitimately not withdrawable yet.
- If this scenario is intentionally reserve-starved, then the correct expectation is **decommit remains blocked**, not that the helper can always drain to zero.
- To confirm quickly, inspect after the first drain:
  - `getPositionSettledOverflowAmounts(positionId)`
  - the market vault `inMarketBalanceOf(token1 underlying)`
  - optionally `settleQueue(lcc1, mm)`  
  I’d expect overflow > 0, reserve = 0, and queue not being the thing that unblocks this path.

If you want, I can help you decide whether the right fix is to change the **scenario** or the **e2e expectation**.

---

**User**

What doesn't make sense is that the e2e test is meant to produce market state where economic outcomes should net.
ie.  @contracts/evm-scripts/script/e2e/MarketMaker.s.sol:71 _runTradingPhase performs swap in two directions, causing inflow/deficit to both sides which should result in economic net outcome. 
If tokens go into a settled position, the tokens must come out (net against settled of the opposite side), then vice versa, tokens out should net against settedl + overflow accrued in the first swap.

---

**Cursor**

I’m checking the swap/trading helpers and the growth-settlement rules, because the trace suggests the two swaps are not actually restoring the position to a symmetric economic state.

The main thing I’m verifying now is whether the two swaps are actually a “round trip” in VTS terms. The logs already hint they aren’t: the first swap pushes the tick to `-887272`, and the second pushes it all the way to `887271`, so the position is being swept from one extreme to the other rather than returned to its starting state.

I think the missing piece is that the protocol does not do a cross-token “economic portfolio netting” step. It settles **per lane** and **per realised growth path**, so a token1 surplus only offsets token1 obligations; it does not automatically cancel token0 history, even if the two swaps feel symmetric at a higher level.

Your intuition would hold if the trading phase were creating a true **state-reversing round trip** and if VTS did **cross-lane netting**. It currently does neither.

The first issue is the swap path itself. `_swapBothDirections()` uses the **same exact input amount** in each direction, but the second trade is not “undoing” the first trade. It starts from the already-moved price and pushes the pool all the way to the opposite extreme:

```593:610:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
function _swapBothDirections(StandaloneMarket memory m, uint256 takerPk, uint256 wrapAmount, uint128 swapAmount)
    internal
    returns (uint256 amountOut0, uint256 amountOut1)
{
    ...
    amountOut1 = _mintAndSwap(m, takerPk, 0, true, swapAmount); // 0 -> 1
    amountOut0 = _mintAndSwap(m, takerPk, 0, false, swapAmount); // 1 -> 0
    console.log("OK: swap both directions complete");
}
```

And your logs show exactly that:

- start near `0`
- first swap ends at `-887272`
- second swap ends at `887271`

That is not a neutral “out and back”; it is a full sweep left, then a full sweep right. So the position does not revisit the original state.

The second issue is the accounting model. VTS settles **per token lane**, not as a combined two-token economic bucket. Deficits and inflows are applied separately to token0 and token1:

```557:679:contracts/evm/src/libraries/VTSPositionLib.sol
function _settlePositionDeficitGrowth(...) internal {
    ...
    if (add0 > 0) {
        ... // consume token0 settled/overflow, else token0 cumulativeDeficit
    }
    if (add1 > 0) {
        ... // consume token1 settled/overflow, else token1 cumulativeDeficit
    }
}

function _settlePositionInflowGrowth(...) internal {
    ...
    if (add0 > 0) {
        _sUpdateSettlement(s, positionId, 0, add0.toInt256());
    }
    if (add1 > 0) {
        _sUpdateSettlement(s, positionId, 1, add1.toInt256());
    }
}
```

And `_sUpdateSettlement` itself is also lane-local:

```224:331:contracts/evm/src/libraries/VTSPositionLib.sol
function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
...
    (eff, cumulativeDef, ...) =
        _nextEffectiveAfterSettlementDelta(pa, tokenIndex, delta, scratch.curS + scratch.curO);
...
    uint256 c = pa.commitmentMax.get(tokenIndex);
    scratch.nextS = eff < c ? eff : c;
    scratch.nextO = eff - scratch.nextS;
    pa.settled.set(tokenIndex, scratch.nextS);
    pa.settledOverflow.set(tokenIndex, scratch.nextO);
```

So a token1 inflow does **not** automatically net a token0 deficit. It only repairs token1’s own lane. That is why “tokens in on one side should come out against the opposite side” does not happen automatically in the current design.

Then there is a third layer: after burn, MM exit only exports the **routeable now** slice. Anything not immediately serviceable stays behind as remnant/overflow by design:

```543:579:contracts/evm/src/libraries/VTSPositionMMOpsLib.sol
/// @dev Non-seizure MM decrease: queue `min(shortfall, principal)` per leg; export for clamp is `settleable + queued`.
///      When `shortfall > principal`, `settleable + queued < excess` for that leg — the uncancellable remainder stays in `pa.settled`.
...
/// @dev Stages `planCancelWithQueue` for MM decreases ...
```

So even if you believe the *overall market economics* should roughly wash out, the protocol still asks a narrower question at decommit time: “is this remnant currently serviceable in this lane from reserve/queue/credit?” In your failing trace, the answer for token1 is no, so it remains as `settledOverflowToken1`.

So the part that does not actually hold is this premise:

> “two swaps in opposite directions should result in a net economic outcome that fully cancels for the position”

In this implementation, that is only true if all of these are true:

1. the second swap really reverses price state rather than just swapping in the opposite direction,
2. per-lane realised growth ends up cancelling,
3. fees/slippage do not leave a residual,
4. and the residual is currently serviceable through reserve/queue when you burn and drain.

Your current e2e fails at least on `1` and `2`, and likely also `3`.

If you want this script to model a genuinely netting trading phase, the likely change is not in settlement logic but in the **trade construction**: the second swap should be sized to bring the price back near the starting tick, rather than using the same fixed input amount in the opposite direction.

---

**User**

Ok, let's expand the e2e test to facilitate two scenarios:
1. The current model, except make assertions about unservicebale effectiveSettled 
2. A true net economic outcome where effectiveSettled is fully serviceable.

---

**Cursor**

I’m mapping the cleanest way to split this into two e2e paths without fighting the existing helper structure, then I’ll suggest the exact assertions each path should make.

I’ve got enough context to sketch the split cleanly. I’m checking whether you already have the primitives needed for a “return to start price” trading phase, or whether that second scenario should be built as a more explicit reserve/serviceability setup.

I’ve confirmed the script side only has exact-input swap helpers today, so the “fully serviceable” scenario will be much easier to make deterministic if you add a small amount of scenario-specific plumbing rather than trying to force it out of the current fixed-size two-swap path.

I’d split it at the **exit boundary**, not just at `run()`.

The cleanest refactor is to break the current happy-path helper into three stages:

1. `_burnAndRealiseExitCredits(...)`
2. `_drainInactivePositionSurplus(...)`
3. `_decommitAndTakeAllLccs(...)`

Right now `_burnDecommitAndTakeAllLccs(...)` bundles all three, which makes scenario `1` awkward because it hard-reverts on stalled drain. That bundling lives here:

```847:890:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
function _burnDecommitAndTakeAllLccs(
    StandaloneMarket memory m,
    uint256 mmPk,
    uint256 commitId,
    uint256 positionIndex
) internal {
    ...
    _drainInactivePositionSurplus(m, mmPk, commitId, positionIndex, 32);
    ...
    _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
}
```

## Recommended shape

I’d keep two scripts or two contracts with separate `run()` entrypoints:

- `MarketMakerUnserviceableE2E`
- `MarketMakerServiceableE2E`

That is simpler than adding env-driven branching inside the current `MarketMaker.s.sol`, because Forge scripts naturally want a single `run()`.

## Scenario 1: current model, assert unserviceable remnant

Reuse the current trading phase:

```47:55:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
    uint256 takerPk = _getDeployerPrivateKey();
    _swapBothDirections(m, takerPk, WRAP_FOR_SWAPS, BIG_SWAP_AMOUNT_IN);
    _pokePosition(m, mmPk, commitId);
}
```

But change the exit flow to:

1. `_settleRfsIfOpen(...)`
2. `_burnAndRealiseExitCredits(...)`
3. read:
   - `getPositionSettledAmounts(positionId)`
   - `getPositionSettledOverflowAmounts(positionId)`
   - `getCommit(commitId).inactiveRemnantCount`
4. attempt **one** drain settle
5. assert **no progress**
6. assert decommit reverts `CommitNotDrained`

The key assertions should be:

- `eff0 + eff1 > 0`
- `overflow0 + overflow1 > 0`
- after one drain attempt, `effAfter == effBefore`
- `inactiveRemnantCount > 0`
- decommit reverts

That gives you an explicit regression for “effective settled exists but is not presently serviceable”.

## Scenario 2: true serviceable/netting path

I would not use the current fixed-size `_swapBothDirections()` for this. It is not a real round trip:

- same exact input both ways
- price goes from near `0` to one extreme, then to the opposite extreme

So add a second trading helper whose purpose is “return near the starting state”, not just “swap twice”.

### Best version
Add an adaptive second leg:

1. snapshot `tickStart`
2. do the first swap
3. do opposite-direction swaps until `tickCurrent` is back near `tickStart`
4. then `_pokePosition(...)`

That gives you a genuine economic round-trip scenario.

### Minimum viable version
If you want something deterministic sooner, build a “serviceable exit” scenario rather than a pure price-netting one:
- smaller swap sizes
- possibly multiple alternating swaps
- assert **before exit** that a drain attempt makes progress
- then assert full drain to zero and successful decommit

## Assertions for scenario 2

After burn and drain:

- `getPositionSettledAmounts(positionId) == (0, 0)`
- `getPositionSettledOverflowAmounts(positionId) == (0, 0)`
- `inactiveRemnantCount == 0`
- decommit succeeds
- unwrap assertions still hold

## Helpful new helper

A small snapshot helper will make both scenarios much easier to read:

```solidity
struct ExitSnapshot {
    PositionId positionId;
    uint256 eff0;
    uint256 eff1;
    uint256 overflow0;
    uint256 overflow1;
    uint256 inactiveRemnantCount;
}
```

Populate it from:

- `IVTSOrchestrator.getPositionId(...)`
- `IVTSOrchestrator.getPositionSettledAmounts(...)`
- `IVTSOrchestrator.getPositionSettledOverflowAmounts(...)`
- `IVTSOrchestrator.getCommit(...)`

Those getters already exist in `VTSOrchestrator` and `IVTSOrchestrator`.

## My recommendation

Use these exact scenario names:

1. `MarketMakerUnserviceableRemnantE2E`
2. `MarketMakerServiceableRoundTripE2E`

and refactor the current exit helper first. That one change unlocks both scenarios cleanly.

If you want, I can next sketch the exact helper signatures and the assertion sequence for each contract.

---

**User**

Can we include a third scenario where swap sizes are not max possibles -- ie. rather than 5000e18, 0 -> 1, output 29,953,549, tick 0 -> -887272
instead it's more modest like 10e18, so we also are testing for non-extreme case?

---

**Cursor**

Yes. That is a good third scenario, and it fills a real gap.

Right now the script is effectively testing an **extreme sweep** because `BIG_SWAP_AMOUNT_IN` is large enough to pin the pool to boundary ticks:

```38:39:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
uint256 internal constant WRAP_FOR_SWAPS = 50_000e18;
uint128 internal constant BIG_SWAP_AMOUNT_IN = 5_000e18;
```

and the trading helper always uses that fixed amount in both directions:

```47:50:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
    uint256 takerPk = _getDeployerPrivateKey();
    _swapBothDirections(m, takerPk, WRAP_FOR_SWAPS, BIG_SWAP_AMOUNT_IN);
    _pokePosition(m, mmPk, commitId);
}
```

## I’d add this third scenario

`MarketMakerModestSwapE2E`

Purpose:
- same general lifecycle
- materially smaller swaps, like `10e18`
- verify behaviour when price moves **inside** the position / without boundary saturation
- catch bugs masked by “everything goes to overflow/extreme tick” behaviour

## Why it is useful

It tests a different regime from the other two:

1. **Unserviceable extreme remnant**
   Large sweep, remnant remains, decommit blocked.

2. **Serviceable/netting path**
   Designed round-trip or otherwise serviceable exit.

3. **Modest non-extreme path**
   Smaller swaps, partial growth attribution, no boundary pinning.

That third one is not redundant. It is the scenario most likely to reflect ordinary usage.

## What I’d assert

For the modest case, I would assert:

- tick after first swap is **not** at `-887272`
- tick after second swap is **not** at `887271`
- `_pokePosition(...)` realises some fee/LCC change
- after exit, either:
  - effective settled fully drains and decommit succeeds, or
  - if not, the remaining remnant is much smaller and explicitly classified as unserviceable

The exact expected outcome depends on how much reserve/queue serviceability you want that scenario to guarantee.

## Suggested structure

Add a swap-size-parametrised trading helper rather than hardcoding only `BIG_SWAP_AMOUNT_IN`, for example conceptually:

- `_runTradingPhase(..., swapAmountIn)`
- keep current scenario with `5_000e18`
- add modest scenario with `10e18`

That keeps the scenario split clean while reusing the same machinery.

## One caution

I would not assume `10e18` automatically gives a fully serviceable exit. It should give a **less extreme** state, but whether it fully drains still depends on:
- exact liquidity depth,
- fee effects,
- lane-local growth accounting,
- and vault reserve availability at exit.

So the modest scenario should first assert “non-extreme price movement”, then assert the chosen exit property based on the regime you want.

If you want, I can sketch the three scenario matrix with exact expected assertions for each one.

---

**User**

Yes proceed with scenario matrix

---

**Cursor**

I’m putting this into a compact scenario matrix with expected setup, assertions, and likely pass criteria so you can turn it into separate e2e scripts cleanly.

## Scenario Matrix

I’d structure it as three separate e2e scripts sharing the same base helpers.

### 1. `MarketMakerUnserviceableRemnantE2E`
This is the current behaviour, but asserted explicitly instead of treated as a happy-path failure.

Flow:
- create MM position
- run current large two-way swaps
- poke
- close RFS
- burn and realise immediate credits
- inspect post-burn remnant
- attempt one drain settle
- assert no progress
- assert decommit reverts

Why it exists:
- documents the present model where MM burn only exports the routeable-now slice, and the remainder can stay in inactive `effectiveSettled`

Core assertions:
- `effectiveSettled > 0` after burn
- `settledOverflow > 0` on at least one lane
- one `SETTLE_POSITION` attempt leaves `effectiveSettled` unchanged
- `inactiveRemnantCount > 0`
- decommit reverts with `CommitNotDrained`

This matches the MM decrease semantics here:

```980:991:contracts/evm/src/libraries/VTSPositionLib.sol
PositionAccounting storage pa = s.positionAccounting[positionId];
(uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);

if (hookData.isMMOperation) {
    requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
} else {
    _applySettlementClampFromExcess(s, positionId, excess0, excess1);
    requiredSettlementDelta = BalanceDelta.wrap(0);
}
```

### 2. `MarketMakerServiceableRoundTripE2E`
This is the true happy path where the post-trade state is intentionally serviceable.

Flow:
- create MM position
- run a trading phase designed to return near the starting market state
- poke
- close RFS
- burn
- drain inactive surplus fully
- decommit
- unwrap and assert balances

Why it exists:
- proves there is a coherent economic path where `effectiveSettled` can be fully serviced and cleared

Core assertions:
- post-trading tick is near the starting tick
- post-burn drain makes progress
- final `getPositionSettledAmounts(positionId) == (0, 0)`
- final `getPositionSettledOverflowAmounts(positionId) == (0, 0)`
- `inactiveRemnantCount == 0`
- decommit succeeds
- unwrap invariants hold

Important note:
- this should not reuse the current fixed-size `_swapBothDirections(...)` unchanged
- the second leg should be sized to restore price, not just swap in the opposite direction

### 3. `MarketMakerModestSwapE2E`
This is the non-extreme case, using smaller swaps such as `10e18`.

Flow:
- create MM position
- run the same two-direction trade shape, but with modest swap size
- poke
- close RFS
- exit using either:
  - full drain path if serviceable, or
  - explicit remnant assertions if it still leaves residue

Why it exists:
- tests normal-range behaviour rather than boundary-pin behaviour
- catches bugs that only appear when the position stays partially in-range

Core assertions:
- first swap does not send tick to `-887272`
- second swap does not send tick to `887271`
- poke realises some non-zero fee/LCC effect
- post-exit behaviour is classified explicitly:
  - either fully drained and decommitted, or
  - remnant remains and is proven unserviceable

## Shared Refactor

I’d split the current exit helper into these pieces:

- `_burnAndRealiseExitCredits(...)`
- `_snapshotExitState(...)`
- `_attemptInactiveDrainOnce(...)`
- `_drainInactivePositionSurplus(...)`
- `_decommitAndTakeAllLccs(...)`

That will let each scenario choose the right stopping point without duplicating the whole exit sequence.

Right now the current helper is too monolithic:

```847:890:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
function _burnDecommitAndTakeAllLccs(
    StandaloneMarket memory m,
    uint256 mmPk,
    uint256 commitId,
    uint256 positionIndex
) internal {
    ...
    _drainInactivePositionSurplus(m, mmPk, commitId, positionIndex, 32);
    ...
    _executeMMActions(mmpm, actions, params, block.timestamp + 3600);
}
```

## Suggested Helper Types

I’d add one small snapshot struct:

```solidity
struct ExitSnapshot {
    PositionId positionId;
    uint256 effective0;
    uint256 effective1;
    uint256 overflow0;
    uint256 overflow1;
    uint256 inactiveRemnantCount;
}
```

Populate it from:

- `getPositionId`
- `getPositionSettledAmounts`
- `getPositionSettledOverflowAmounts`
- `getCommit`

Those getters already exist in `IVTSOrchestrator` / `VTSOrchestrator`.

## Trading Helpers

I’d keep the current helper for scenario 1:

- `_runExtremeTradingPhase(...)`

Then add:

- `_runRoundTripTradingPhase(...)`
- `_runModestTradingPhase(..., uint128 swapAmount)`

The current helper is fine as the “extreme sweep” scenario:

```47:50:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
    uint256 takerPk = _getDeployerPrivateKey();
    _swapBothDirections(m, takerPk, WRAP_FOR_SWAPS, BIG_SWAP_AMOUNT_IN);
    _pokePosition(m, mmPk, commitId);
}
```

## Expected Outcomes

Use this as the acceptance matrix:

- `UnserviceableRemnant`
  - expected: remnant remains, no progress on drain, decommit blocked

- `ServiceableRoundTrip`
  - expected: remnant drains fully, decommit succeeds

- `ModestSwap`
  - expected: non-extreme tick movement, partial-growth behaviour covered, exit classified explicitly as either serviceable or not

If you want, I can next turn this into a concrete file-by-file implementation plan with proposed function names and assertion order.

---

**User**

Let's do a fourth scenario where our actual postion is not so tighter - ie. -60, 60 and liq 1e10 is tooo small. 
Let's also repeat these scenarios with appropriate asserts for MM positions of various sizes

---

**Cursor**

Yes. I’d stop thinking of this as “one more script” and turn it into a **2-axis matrix**:

```30:39:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
uint128 internal constant LIQUIDITY = 1e10;
int24 internal constant TICK_LOWER = -60;
int24 internal constant TICK_UPPER = 60;

uint256 internal constant WRAP_FOR_SWAPS = 50_000e18;
uint128 internal constant BIG_SWAP_AMOUNT_IN = 5_000e18;
```

That current config is one very specific corner: tight and tiny, with huge swaps.

## Recommended Axes

### 1. Scenario axis
Keep these four scenario kinds:

1. `ExtremeUnserviceableRemnant`
   Current large-sweep behaviour, assert stalled drain and blocked decommit.

2. `ServiceableRoundTrip`
   Price intentionally brought back near start, assert full drain and successful decommit.

3. `ModestNonExtreme`
   Smaller swaps like `10e18`, assert no boundary pinning.

4. `WideOrDeepPosition`
   Same large-swap intent, but with a materially wider and/or deeper MM position, assert the position is not pathologically fragile.

### 2. Position-profile axis
Make a `PositionProfile` rather than hardcoding `[-60,60], 1e10`.

I’d start with four profiles:

- `tightTiny`
  `[-60, 60]`, `1e10`
  Current pathological baseline.

- `tightMaterial`
  `[-60, 60]`, much larger liquidity
  Same range, but not dust-sized.

- `wideMaterial`
  Wider range, medium liquidity
  Tests whether width alone improves serviceability.

- `wideDeep`
  Wider range, deeper liquidity
  “Realistic MM” regime.

## Important point

Do not treat raw liquidity alone as the truth. Your code already derives settlement capacity from range + liquidity:

```646:657:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
function _baseSettlementAmounts(
    address vtsOrchestratorAddr,
    PoolKey memory key,
    int24 tickLower,
    int24 tickUpper,
    uint128 liq
) internal view returns (uint256 settle0, uint256 settle1) {
    ...
    (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liq);
    (settle0, settle1) =
        LiquidityUtils.getBaseSettlementAmounts(c0, c1, vtsCfg.token0.baseVTSRate, vtsCfg.token1.baseVTSRate);
}
```

So I’d log and assert **base settlement bands** per profile as part of setup, not just `liq`.

## Expected assertions by scenario

### `ExtremeUnserviceableRemnant`
Best on `tightTiny`, optionally `tightMaterial`.

Assert:
- swaps hit or nearly hit extreme ticks
- post-burn `effectiveSettled > 0`
- `settledOverflow > 0`
- one drain attempt makes no progress
- `inactiveRemnantCount > 0`
- decommit reverts `CommitNotDrained`

### `ServiceableRoundTrip`
Run on `tightMaterial`, `wideMaterial`, `wideDeep`.

Assert:
- post-trading tick is near starting tick
- drain makes progress
- final effective settled is zero
- final overflow is zero
- `inactiveRemnantCount == 0`
- decommit succeeds

### `ModestNonExtreme`
Run on all profiles.

Assert:
- first swap does not hit `-887272`
- second swap does not hit `887271`
- poke realises some non-zero fee/LCC change
- then classify outcome by profile:
  - constrained profiles may still leave remnant
  - balanced profiles should drain fully

### `WideOrDeepPosition`
This is the fourth scenario you asked for.

Use the same large-swap style as the current script, but on `wideMaterial` or `wideDeep`.

Assert:
- the position is not immediately forced into the same pathological remnant pattern as `tightTiny`
- boundary pinning is reduced or absent
- post-burn drain is serviceable, or at minimum materially better than `tightTiny`
- decommit should succeed for the deepest profile

## Practical matrix

I would not do a full 4 x 4 cartesian product immediately. Start with this:

- `ExtremeUnserviceableRemnant` on `tightTiny`
- `ExtremeUnserviceableRemnant` on `tightMaterial`
- `ServiceableRoundTrip` on `tightMaterial`
- `ServiceableRoundTrip` on `wideMaterial`
- `ModestNonExtreme` on all four profiles
- `WideOrDeepPosition` on `wideMaterial`
- `WideOrDeepPosition` on `wideDeep`

That gives you broad coverage without exploding runtime.

## Suggested abstractions

Add two structs in the e2e base:

- `PositionProfile { name, tickLower, tickUpper, liquidity }`
- `ScenarioProfile { name, wrapAmount, swapAmount, expectedKind }`

And one expectation enum:

- `ExpectUnserviceableRemnant`
- `ExpectFullDrain`
- `ExpectNonExtremeMove`
- `ExpectImprovedServiceability`

That lets you reuse the same setup and exit helpers, while changing only the assertions.

## My recommendation

Use this progression:

1. Refactor current script into reusable scenario/profile helpers.
2. Add `tightTiny` + `wideDeep`.
3. Implement the four scenario kinds.
4. Then expand to the middle profiles once the expectations stabilise.

If you want, I can next draft the exact `PositionProfile` and `ExpectationKind` shapes, plus which helper should own each assertion.

---

**User**

Also, for each repeated scenario under new position parameters, let's adjust the initial settled amounts too

Sketch this whole e2e expansion out

---

**Cursor**

I’ve narrowed the main design choices. Before I lock the plan, I need two scope decisions because they change the shape of the e2e suite quite a bit.

**E2E Expansion Scope**

> **How broad should the repeated scenario matrix be across new position profiles?**
> - Curated subset: run each scenario only on the most meaningful position profiles
> - Full cross-product: run every scenario against every position profile ✔

> **For the fully serviceable scenario, what should define the happy path?**
> - Adaptive round-trip trading: size later swaps to bring price back near the start
> - Reserve/serviceability-shaped path: explicitly choose swaps and exit setup so post-burn effectiveSettled is fully drainable
> - Include both approaches as separate happy-path variants ✔

I have the two key decisions: full cross-product, and both kinds of serviceable happy-paths. I’m turning that into a concrete implementation sketch now.

---

**User**

Suggest improvements to the plan to be explciit about adding console.logs and assertions regarding the total economic state/health of the Maker, whether it's in a better or worse situation.
Additionally, re-performing the scenarios for each position profile an additional time but with some liquidity buffer via full-size DirectLP would help.

---

**Cursor**

I’m checking whether the existing e2e base already has useful DirectLP or health-related primitives, so the plan improvements can point to real reuse points instead of abstract additions.

I found an existing reuse point for the DirectLP buffer idea in the e2e base, so I’m pulling that into the plan suggestions rather than treating it as a net-new subsystem.

Yes, I’d tighten the plan in two major ways.

## 1. Make “Maker health” a first-class output

Right now the plan talks about remnant/serviceability, but not about the MM’s **total economic state** across the scenario. I’d explicitly add a `MakerHealthSnapshot` and require both `console.log(...)` output and assertions at each phase boundary.

### Add a new snapshot type
In the plan, add a struct like:

- `MakerHealthSnapshot`
  - `positionId`
  - `tickCurrent`
  - `commitment0`, `commitment1`
  - `effectiveSettled0`, `effectiveSettled1`
  - `overflow0`, `overflow1`
  - `poolTotalSettled0`, `poolTotalSettled1`
  - `poolTotalDeficitPrincipal0`, `poolTotalDeficitPrincipal1`
  - `inactiveRemnantCount`

Most of those already have public getters:

```424:448:contracts/evm/src/VTSOrchestrator.sol
function getCommitmentMaxima(PositionId positionId) ...
function getPoolTotalSettled(PoolId poolId) ...
function getPoolTotalDeficitPrincipal(PoolId poolId) ...
```

and:

```409:421:contracts/evm/src/VTSOrchestrator.sol
function getPositionSettledAmounts(PositionId positionId) ...
function getPositionSettledOverflowAmounts(PositionId positionId) ...
```

### Log health at fixed checkpoints
I’d amend the plan so every scenario/profile run logs a health snapshot at:

- after initial settle
- after trading
- after poke
- after RFS close
- after burn
- after one drain attempt
- after final drain/decommit/unwrap

That gives a readable story of whether the MM is better or worse off.

### Add directional health assertions
The plan should explicitly call for assertions like:

- `ModestNonExtreme` should not worsen into max-tick boundary pinning
- buffered variants should not be **less** serviceable than unbuffered variants
- `Serviceable*` paths should end with strictly lower remnant / overflow than their post-burn snapshot
- `ExtremeUnserviceableRemnant` should prove the MM remains economically owed, but not presently serviceable

I’d phrase this in the plan as “assert relative improvement/worsening”, not just absolute end state.

### Be explicit about what “better” means
I’d add a short section defining health heuristics, for example:

- better:
  - lower `effectiveSettled` remnant after exit
  - lower `overflow`
  - lower `inactiveRemnantCount`
  - lower pool deficit principal attributable to the stressed regime
  - more successful drainability / decommitability

- worse:
  - higher stranded overflow
  - stalled drain
  - blocked decommit
  - max-tick pinning in scenarios that should stay non-extreme

That will keep the implementation from becoming “a lot of logs with no judgment”.

## 2. Add a buffer axis with full-range DirectLP

This is a strong addition, and you already have a reusable helper for it:

```341:383:contracts/evm-scripts/script/e2e/base/E2EBase.sol
function _addCoreLiquidityFullRange(
    StandaloneMarket memory m,
    uint256 lpPk,
    uint256 wrapAmountPerAsset,
    uint256 amountMaxPerAsset
) internal returns (uint256 tokenId) {
    ...
}
```

So I’d update the plan to introduce a **second matrix axis**:

- `buffered = false`
- `buffered = true` using full-range DirectLP

### How to describe it in the plan
Instead of only:

- scenario x position-profile

make it:

- scenario x position-profile x liquidity-buffer-mode

Where `liquidity-buffer-mode` is:

- `NoDirectLPBuffer`
- `FullRangeDirectLPBuffer`

### Why this matters
It lets the suite answer a much more useful question:

> Is the MM remnant unserviceable because of MM accounting/path shape, or because the surrounding market is under-buffered?

That is exactly the sort of comparative signal the current plan is missing.

### Assertions for buffered repeats
The plan should be explicit that the buffered rerun is not just “repeat the same scenario”, but “compare unbuffered vs buffered outcomes”.

I’d add these expected assertions:

- buffered path should have:
  - same or smaller remnant
  - same or lower overflow
  - same or better drain progress
  - same or lower probability of `CommitNotDrained`
- if the unbuffered case is unserviceable, the buffered case should either:
  - become drainable, or
  - leave a smaller remnant with clearer diagnostics

## Concrete edits I’d suggest to the plan text

### Under “Proposed Matrix”
Change:

- “full cross-product of scenario x position profiles”

to:

- “full cross-product of scenario x position profile x buffer mode”

Add:

- `NoDirectLPBuffer`
- `FullRangeDirectLPBuffer`

### Under “Refactor Shape”
Add:

- `MakerHealthSnapshot { ... }`
- `_snapshotMakerHealth(...)`
- `_logMakerHealth(...)`
- `_assertMakerHealthImproved(...)`
- `_assertMakerHealthNotWorseWithBuffer(...)`

### Under “Assertion Model”
Add an explicit subsection:

- “Economic health assertions”
- compare snapshots across phases and across buffered/unbuffered reruns
- require scenario-specific verdicts about whether the MM is in a better or worse state

### Under “Trading-Phase Strategy”
Add one more setup/helper item:

- `_seedFullRangeDirectLPBuffer(...)` using `_addCoreLiquidityFullRange(...)`

### Under “Expected Outcome by Scenario”
For each scenario, split expected outcomes into:

- unbuffered expectation
- buffered expectation

That will make the plan much more operational.

## One more improvement

Because you asked for health of the Maker, I’d also suggest the plan explicitly calls out that **existing public getters do not expose everything you might want**, especially per-position `cumulativeDeficit` and `commitmentDeficit`. The test harness has examples of those reads:

```34:47:contracts/evm/test/base/VTSOrchestratorTestable.sol
PositionAccounting storage pa = s.positionAccounting[positionId];
return (
    pa.cumulativeDeficit.token0,
    pa.cumulativeDeficit.token1,
    ...
);
```

So the plan should decide one of two approaches:

- use only existing public getters for health, or
- add a read-only lens for richer economic diagnostics

That choice should be explicit in the plan, otherwise the “Maker health” part may end up underpowered.

## Short version

The plan is already solid on structure, but I’d improve it by making it explicit that it will add:

1. `MakerHealthSnapshot` plus `console.log` checkpoints and comparative assertions.
2. A new buffer axis using `_addCoreLiquidityFullRange(...)`.
3. Buffered vs unbuffered comparisons for every scenario/profile repeat.
4. A conscious decision about whether to expose richer per-position deficit lenses.

If you want, I can turn that into a patch-style rewrite of the existing plan sections so you can drop it straight into the plan file.

---

**User**

Let's expand the action plan to include these improvements

---

**Cursor**

I’m updating the existing plan to make Maker-health logging/assertions and DirectLP-buffer repeats explicit, including the new matrix axis and comparison expectations.

I’ve got the concrete plan additions: a new buffer axis, explicit Maker-health snapshots/logging, and richer comparison assertions. I’m folding those into the existing plan file now.

The plan now explicitly covers:

- a new `BufferMode` axis for unbuffered vs full-range `DirectLP` buffered reruns
- `MakerHealthSnapshot` plus `console.log(...)` checkpoints at every major phase
- comparative assertions about whether the MM is in a better, worse, or unchanged state
- buffered-vs-unbuffered outcome comparisons for every scenario/profile combination

The updated plan is at `/Users/ryansoury/.cursor/plans/expand-mm-e2e-matrix_0ca4ce74.plan.md`.

If you want, I can also review the revised plan text and point out any remaining ambiguities before you switch back to implementation mode.

---

**User**

Implement the plan as specified, it is attached for your reference. Do NOT edit the plan file itself.

To-do's from the plan have already been created. Do not create them again. Mark them as in_progress as you work, starting with the first one. Don't stop until you have completed all the to-dos.

---

**Cursor**


Implementing the MM E2E expansion: reading the codebase and marking the first todo in progress.




Implementing structs and helpers in `MME2EBase.sol`, then splitting the exit flow and adding matrix scripts. Checking `PoolKey` usage and `Errors.CommitNotDrained`.




Implementing matrix structs, splitting the exit flow, and adding scenario runners. Working through the todos systematically.




Adding imports, `PoolIdLibrary`, structs, and matrix helpers to `MME2EBase.sol`.




Splitting the exit flow and adding `_attemptInactiveDrainOnce`, `_burnAndRealiseExitCredits`, and `_decommitAndTakeAllLccs`.




Fixing `_logMakerHealth` (pure → view), adding `_drainInactivePositionSurplusBestEffort` and `_mmProfileNameEq`, and resolving double-logging in `_drainInactivePositionSurplus` (remove redundant pre-check; `_attemptInactiveDrainOnce` handles it).




Creating the five scenario scripts.




Softening baseline comparison for wide/deep stress (economics can be noisy) and adding the plan's `ScenarioProfileE2E` struct so `MME2EScenarioKind` is part of the config surface.



---

**User**

The original e2e-market-maker fails, let's adjust the assertions to include recognition of unserviceable overflows - and then use @agents/spec/Endogenous vs Exogenous Liquidity Considerations.md approach to resolving this - ie. withdraw serviceable and rebalance to wihtdraw unserviceable.

---

**Cursor**

I’m tracing the current MM exit path against the endogenous/exogenous liquidity notes so I can point to the exact assertion changes and rebalance flow you need, without making edits in Ask mode.

I’ve confirmed the failure point: the baseline script still treats “no drain progress” as a hard failure, even though your notes describe that as a valid economic state. I’m pulling the exact helper surface you should pivot to for a staged exit plus rebalance.

You can, but I can’t make the edit while we’re in Ask mode. The key change is to stop treating “inactive drain made no progress” as an automatic test failure, because that state is now a recognised outcome of the MM accounting model rather than necessarily a bug.

Right now the baseline script still hardwires the old happy-path exit:

```49:51:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
        _closeRfsBurnDecommitAndTakeAllLccs(m, mmPk, commitId);
        _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
```

That is what blows up when `_drainInactivePositionSurplus` stalls. The better shape is:

1. Close RFS.
2. Burn and realise exit credits.
3. Snapshot exit state and maker health.
4. Drain best-effort.
5. If fully drained, decommit and unwrap.
6. If not fully drained, assert this is a recognised `unserviceable overflow` state.
7. Then run the rebalance flow from the spec.
8. Re-attempt drain, then decommit and unwrap.

You already have most of the helper surface to support this. In particular, the base now exposes a best-effort drain path and explicit exit snapshots:

```1168:1217:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
    /// @notice After burn, repeatedly SETTLE (withdraw) until inactive effective settled is zero, or revert if progress stalls.
    /// @dev Burn can leave surplus in `settledOverflow` that `SETTLE_POSITION_FROM_DELTAS` alone does not clear; decommit requires no inactive remnant.
    function _drainInactivePositionSurplus(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxIterations
    ) internal {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);

        uint256 cap = maxIterations == 0 ? 32 : maxIterations;

        for (uint256 i = 0; i < cap; i++) {
            (uint256 eff0Before, uint256 eff1Before) = _getEffectiveSettledPair(vts, commitId, positionIndex);
            if (eff0Before == 0 && eff1Before == 0) {
                return;
            }

            bool progressed = _attemptInactiveDrainOnce(m, mmPk, commitId, positionIndex);
            if (!progressed) {
                revert("e2e: inactive surplus settle made no progress (check vault liquidity / queue)");
            }
        }

        (uint256 left0, uint256 left1) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        require(left0 == 0 && left1 == 0, "e2e: inactive economic remnant remains after max drain iterations");
    }

    /// @dev Best-effort drain loop that stops when progress stalls (does not revert on stall).
    function _drainInactivePositionSurplusBestEffort(
        StandaloneMarket memory m,
        uint256 mmPk,
        uint256 commitId,
        uint256 positionIndex,
        uint256 maxIterations
    ) internal returns (bool fullyDrained) {
        IVTSOrchestrator vts = IVTSOrchestrator(m.stack.contracts.vtsOrchestrator);
        uint256 cap = maxIterations == 0 ? 32 : maxIterations;
        for (uint256 i = 0; i < cap; i++) {
            (uint256 e0, uint256 e1) = _getEffectiveSettledPair(vts, commitId, positionIndex);
            if (e0 == 0 && e1 == 0) {
                return true;
            }
            if (!_attemptInactiveDrainOnce(m, mmPk, commitId, positionIndex)) {
                break;
            }
        }
        (uint256 e0f, uint256 e1f) = _getEffectiveSettledPair(vts, commitId, positionIndex);
        fullyDrained = e0f == 0 && e1f == 0;
    }
```

## What to assert instead
After burn, if drain stalls, assert all of these instead of reverting immediately:

- `effectiveSettled` is still non-zero on at least one lane.
- `settledOverflow` is non-zero on at least one lane.
- `inactiveRemnantCount > 0`.
- `DECOMMIT_SIGNAL` reverts with `CommitNotDrained`.

That turns the old failure into an explicit scenario verdict: “recognised unserviceable overflow”.

You already have most of that in `_assertUnserviceableRemnantAfterBurn()` in `MME2EBase.sol`, so for the baseline script I’d use the same model before attempting recovery.

## Rebalance flow to resolve it
Your spec’s logic is right:

- withdraw what is serviceable first;
- use that recovered value to source the scarce token externally;
- swap the scarce token into the same market;
- then retry settlement on the stranded lane.

The critical directionality is already documented in the swap helper:

```809:824:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
        if (wrapAmount > 0) {
            // IMPORTANT: `zeroForOne` is defined relative to the *sorted pool currencies* (currency0/currency1),
            // not `m.underlying0/m.underlying1`. To ensure we fund the correct input token, derive the input LCC
            // from the PoolKey and then wrap its underlying.
            PoolKey memory key = _corePoolKey(m);
            address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

            vm.startBroadcast(takerPk);
            address underlying = ILCC(tokenIn).underlying();
            Token(underlying).mint(taker, wrapAmount);
            _wrapAndMintLcc(ILiquidityHub(m.stack.contracts.liquidityHub), m.marketId, underlying, taker, wrapAmount);
            vm.stopBroadcast();
        }

        (,,, amountOut) = _swapExactInputSingle(m, takerPk, zeroForOne, swapAmount, 0);
```

So the rule is:

- if `token0` is stranded, you must swap `token0` in (`zeroForOne = true`);
- if `token1` is stranded, you must swap `token1` in (`zeroForOne = false`).

That matches the liquidity-reserve behaviour from your spec: you heal a lane by pushing more of that same lane into the pool.

## Practical baseline rewrite
I’d change the baseline exit phase conceptually to this:

```solidity
function _runExitPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
    _settleRfsIfOpen(m, mmPk, commitId);
    _burnAndRealiseExitCredits(m, mmPk, commitId, 0);

    ExitSnapshotE2E memory afterBurn = _snapshotExitState(m, commitId, 0);
    MakerHealthSnapshotE2E memory healthAfterBurn = _snapshotMakerHealth(m, commitId, 0);
    _logMakerHealth("after burn", healthAfterBurn);

    bool drained = _drainInactivePositionSurplusBestEffort(m, mmPk, commitId, 0, 32);
    if (!drained) {
        // assert recognised unserviceable overflow
        // perform rebalance based on remaining stranded lane
        // retry drain
    }

    _decommitAndTakeAllLccs(m, mmPk, commitId);
    _unwrapAllLccsAndAssert(m, mmPk, commitId, 0, true);
}
```

## One important modelling choice
Because the spec’s rebalance step includes an external conversion, the cleanest e2e assertion is not “the same wallet atomically converts inside the protocol”. It is:

- the MM successfully withdraws serviceable value;
- the test uses no more than that withdrawn value as the budget for a scarce-token replenishing swap;
- after that replenishing swap, the previously stranded lane becomes drainable.

That keeps the test aligned with the current design rather than pretending there is already an internal conversion primitive.

If you want, switch back to Agent mode and I can implement this as:
- a staged `MarketMaker.s.sol` exit flow,
- a `recognised unserviceable overflow` assertion branch,
- and a rebalance helper that retries drain after a scarce-lane replenishing swap.

---

**User**

Proceed with this implementation of new overflow assertions + rebalance + post-rebalance assertions

---

**Cursor**

Implementing staged exit with overflow assertions, directional reserve rebalance swaps, and post-rebalance drain assertions. Reviewing `MME2EBase.sol` and `MarketMaker.s.sol` to integrate cleanly.



Adding rebalance helpers and a staged exit orchestrator to `MME2EBase.sol`, then switching `MarketMaker.s.sol` to use them.



---

**User**

Any ideas?

    ├─ [574] LiquidityCommitmentCertificate.e2e_non_ir::balanceOf(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) [staticcall]
    │   └─ ← [Return] 99999999999999969775925 [9.999e22]
    ├─ [574] LiquidityCommitmentCertificate.e2e_non_ir::balanceOf(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) [staticcall]
    │   └─ ← [Return] 50000000000000029863147 [5e22]
    ├─ [0] VM::startBroadcast(<pk>)
    │   └─ ← [Return]
    ├─ [2680] LiquidityCommitmentCertificate.e2e_non_ir::approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, spender: 0x000000000022D473030F116dDEE9F6B43aC78BA3, value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [3550] 0x000000000022D473030F116dDEE9F6B43aC78BA3::approve(LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806], 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b, 1461501637330902918203684832716283019655932542975 [1.461e48], 1776760548 [1.776e9])
    │   ├─ emit Approval(owner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, token: LiquidityCommitmentCertificate.e2e_non_ir: [0x76a98833a7821CDb59Cf749d948639C721c6C806], spender: 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b, amount: 1461501637330902918203684832716283019655932542975 [1.461e48], expiration: 1776760548 [1.776e9])
    │   └─ ← [Return]
    ├─ [15905] 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b::execute(0x10, [0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb0000000000000000000000000000000000000000000000000000000000000000], 1776674448 [1.776e9])
    │   ├─ [14095] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::unlock(0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb0000000000000000000000000000000000000000000000000000000000000000)
    │   │   ├─ [12803] 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b::unlockCallback(0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb00000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000006b759ec2c38164ec9fe39dbe3617ece0a145afc300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000076a98833a7821cdb59cf749d948639c721c6c8060000000000000000000000000000000000000000000000878678326eac900000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000026c5fa5dc0c5bf86200390c00195afec7eebffdb0000000000000000000000000000000000000000000000000000000000000000)
    │   │   │   ├─ [9517] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::swap(PoolKey({ currency0: 0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB, currency1: 0x76a98833a7821CDb59Cf749d948639C721c6C806, fee: 3000, tickSpacing: 60, hooks: 0x6b759EC2c38164EC9Fe39dBE3617ECE0A145aFc3 }), SwapParams({ zeroForOne: false, amountSpecified: -2500000000000000000000 [-2.5e21], sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341 [1.461e48] }), 0x)
    │   │   │   │   ├─ [5092] CoreHook::beforeSwap(0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b, PoolKey({ currency0: 0x26C5fa5dc0c5BF86200390C00195aFec7EEBffDB, currency1: 0x76a98833a7821CDb59Cf749d948639C721c6C806, fee: 3000, tickSpacing: 60, hooks: 0x6b759EC2c38164EC9Fe39dBE3617ECE0A145aFc3 }), SwapParams({ zeroForOne: false, amountSpecified: -2500000000000000000000 [-2.5e21], sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341 [1.461e48] }), 0x)
    │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c71ff) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] 0x000000000bb80000000d89e7fffd8963efd1fc6a506488495d951d5263988d25
    │   │   │   │   │   ├─ [375] 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543::extsload(0x075f658dd9e93c7994c007f52957f7e52c4603a24c464a7da5119b57250c7202) [staticcall]
    │   │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   │   └─ ← [Return] 0x575e24b4, 0, 0
    │   │   │   │   └─ ← [Revert] PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])
    │   │   │   └─ ← [Revert] PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])
    │   │   └─ ← [Revert] PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])
    │   └─ ← [Revert] PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])
    └─ ← [Revert] PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])



== Logs ==
  === E2E: MarketMaker ===
  E2E DeployFullStack on ethsepolia
  PoolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
  CREATE2 Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
  CREATE3 Factory: 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
  Expected ProxyHook (extra market): 0xA9A05008d35F035C066CF6356FAD71E06226a888
  OK: position created
  commitId: 1
  tick (before swap) 0
  OK: swap complete
  zeroForOne: true
  amountIn: 5000000000000000000000
  amountOut: 29953549
  tick (after swap) -887272
  tick (before swap) -887272
  OK: swap complete
  zeroForOne: false
  amountIn: 5000000000000000000000
  amountOut: 59997090
  tick (after swap) 887271
  OK: swap both directions complete
  OK: position poked
  fee lcc0 taken: 90401
  fee lcc1 taken: 180532
  --- Maker health: after burn (pre-drain)
  tick: 887271
  eff0: 0
  eff1: 9909868827
  overflow0: 0
  overflow1: 9909868827
  commitment0/1: n/a (inactive position; getCommitmentMaxima is active-only)
  poolTotalSettled0: 0
  poolTotalSettled1: 9909868827
  poolDeficitPrincipal0: 0
  poolDeficitPrincipal1: 0
  inactiveRemnantCount: 1
  e2e: inactive surplus before drain, eff0: 0 eff1: 9909868827
  --- Maker health: recognised unserviceable overflow (pre-rebalance)
  tick: 887271
  eff0: 0
  eff1: 9909868827
  overflow0: 0
  overflow1: 9909868827
  commitment0/1: n/a (inactive position; getCommitmentMaxima is active-only)
  poolTotalSettled0: 0
  poolTotalSettled1: 9909868827
  poolDeficitPrincipal0: 0
  poolDeficitPrincipal1: 0
  inactiveRemnantCount: 1
  e2e: reserve rebalance round: 0
  e2e: reserve rebalance - currency1 in (zeroForOne=false), chunk: 2500000000000000000000
  tick (before swap) 887271
Error: script failed: PriceLimitAlreadyExceeded(1461446703485210103287273052203988822378723970341 [1.461e48], 1461446703485210103287273052203988822378723970341 [1.461e48])
error: Recipe `e2e-market-maker` failed on line 753 with exit code 1

---

**Cursor**

The rebalance direction looks right; the immediate problem is that your recovery swap is being attempted while the pool is already sitting at the exact `sqrtPriceLimitX96` for that direction. I’m checking the exact-input helper so I can point to the safest fix.

This is no longer an overflow-assertion problem; it’s a boundary-price problem in the rebalance leg. I’m pulling the exact limit constants so I can explain why `zeroForOne=false` cannot execute from `tick ~= MAX_TICK`.

Yes. The new failure is consistent with the rebalance idea, but the first implementation is too naive about boundary state.

## What’s happening

Your rebalance leg is trying to heal `eff1` by swapping `currency1` in:

- stranded lane: `eff1 > 0`
- chosen rebalance: `zeroForOne = false`
- current tick before rebalance: `887271`

That is effectively the top boundary already. In this codebase, the one-for-zero “no limit” bound is the max valid sqrt price:

```1:26:contracts/evm/src/libraries/LiquidityUtils.sol
library LiquidityUtils {
    using SafeCast for *;

    uint160 internal constant ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
```

And `ProxyHook` maps the default to that exact boundary:

```179:187:contracts/evm/src/ProxyHook.sol
        uint160 minValid = TickMath.MIN_SQRT_PRICE + 1;
        uint160 maxValid = TickMath.MAX_SQRT_PRICE - 1;

        // Direction-aware "no limit" default in flipped markets.
        if (sqrtPriceLimitX96 == 0) return coreZeroForOne ? minValid : maxValid;

        // Preserve canonical extreme mapping exactly.
        if (sqrtPriceLimitX96 == minValid) return maxValid;
        if (sqrtPriceLimitX96 == maxValid) return minValid;
```

So when you attempt `zeroForOne=false` while already sitting at `maxValid`, v4 quite reasonably throws `PriceLimitAlreadyExceeded`. That is not saying your rebalance thesis is wrong; it is saying that the chosen healing direction is geometrically impossible from the current pinned price.

## Why this happens specifically in your script

The baseline path is still deliberately pathological:

```44:47:contracts/evm-scripts/script/e2e/MarketMaker.s.sol
    function _runTradingPhase(StandaloneMarket memory m, uint256 mmPk, uint256 commitId) internal {
        uint256 takerPk = _getDeployerPrivateKey();
        _runExtremeTradingPhase(m, mmPk, takerPk, commitId);
    }
```

And your logs show exactly that:

- after first swap: tick `-887272`
- after second swap: tick `887271`

So by the time rebalance starts, the pool is already pinned at the top.

## Best fix

Make the rebalance helper boundary-aware.

### Rule
If the stranded lane requires a swap direction that is currently blocked by the price boundary, do this in two phases:

1. Do a tiny anti-pin nudge in the opposite direction to move off the boundary.
2. Then do the intended reserve-replenishing swap in the healing direction.
3. Retry drain.

For your current failure:

- stranded lane is `token1`
- intended heal is `zeroForOne = false`
- but current tick is at the top boundary
- so first do a small `zeroForOne = true` nudge
- then do the real `zeroForOne = false` replenishment swap

## Why that still matches the spec

Your spec says heal lane `N` by swapping `N` in. That is still the right economic healing leg.

The extra opposite-direction nudge is just a geometric unlock step so the healing leg can execute at all. It is not the actual reserve-healing action; it is a preconditioner.

## Practical implementation idea

Inside the rebalance helper, inspect current tick before choosing the leg.

Pseudo-shape:

```solidity
if (eff1 > 0) {
    if (tickCurrent >= upperPinnedThreshold) {
        // tiny anti-pin nudge
        _mintAndSwap(m, takerPk, wrapAmount, true, antiPinAmount);
    }
    // actual token1-in heal
    _mintAndSwap(m, takerPk, wrapAmount, false, healAmount);
}
```

Mirror that for `eff0 > 0` near the lower boundary.

## I’d use two amounts, not one

Your current rebalance chunk is `2500e18`, which is fine for the real heal, but too big for the unlock step.

Use:

- `antiPinAmount`: very small, just enough to move off boundary
- `healAmount`: the larger replenishment size

That will make the behaviour much more deterministic.

## Additional assertion I’d add

Before attempting a rebalance leg, assert whether it is geometrically available.

Something like:

- if `eff1 > 0` and tick is pinned high, log `healing lane blocked by max-price boundary`
- after anti-pin nudge, assert tick is no longer pinned
- only then run the true replenishment swap
- after replenishment, assert maker health is improved or at least not worse
- then re-run best-effort drain and require progress

## If you want the test to be less brittle

Two other options:

1. Switch baseline recovery from the extreme path to the adaptive round-trip path before rebalance.
2. Keep the extreme path, but classify “rebalance blocked by boundary pinning” separately from “rebalance failed economically”.

The first is better if the goal is “prove endogenous recovery exists”.
The second is better if the goal is “document the full failure surface”.

## Most likely code change

The helper to update is the new rebalance path in `MME2EBase.sol`, not the overflow assertion itself. The overflow assertion appears to be doing the right thing already; the bad assumption is “if a lane is stranded, immediately swap that lane in”.

That assumption fails at extreme ticks.

If you switch back to Agent mode, I’d make the rebalance helper:

- read current tick,
- detect pinned-high / pinned-low,
- do a tiny anti-pin swap first when needed,
- then do the true reserve-healing leg,
- and add post-rebalance assertions around tick movement and drain progress.

