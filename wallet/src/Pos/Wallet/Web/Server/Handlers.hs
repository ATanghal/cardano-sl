{-# LANGUAGE Rank2Types   #-}
{-# LANGUAGE TypeFamilies #-}

-- | Wallet endpoints list

module Pos.Wallet.Web.Server.Handlers
       ( servantHandlers
       , servantHandlersWithSwagger
       ) where

import           Universum

import           Ntp.Client (NtpStatus)
import           Pos.Wallet.Web.Swagger.Spec (swaggerSpecForWalletApi)
import           Servant.API ((:<|>) ((:<|>)))
import           Servant.Generic (AsServerT, GenericProduct, ToServant,
                     toServant)
import           Servant.Server (Handler, Server, ServerT, hoistServer)
import           Servant.Swagger.UI (swaggerSchemaUIServer)

import           Pos.Core.Txp (TxAux)
import           Pos.Crypto (ProtocolMagic)
import           Pos.Update.Configuration (curSoftwareVersion)
import           Pos.Util.CompileInfo (HasCompileInfo)
import           Pos.Util.Trace.Named (TraceNamed)

import           Pos.Wallet.WalletMode (blockchainSlotDuration)
import           Pos.Wallet.Web.Account (GenSeed (RandomSeed))
import qualified Pos.Wallet.Web.Api as A
import qualified Pos.Wallet.Web.Methods as M
import           Pos.Wallet.Web.Mode (MonadFullWalletWebMode)

----------------------------------------------------------------------------
-- The wallet API with Swagger
----------------------------------------------------------------------------

servantHandlersWithSwagger
    :: ( MonadFullWalletWebMode ctx m
       , HasCompileInfo
       )
    => TraceNamed m
    -> ProtocolMagic
    -> TVar NtpStatus
    -> (TxAux -> m Bool)
    -> (forall x. m x -> Handler x)
    -> Server (A.WalletSwaggerApi (TraceNamed m))
servantHandlersWithSwagger logTrace pm ntpStatus submitTx nat =
    hoistServer A.walletApi nat (servantHandlers logTrace pm ntpStatus submitTx)
   :<|>
    swaggerSchemaUIServer swaggerSpecForWalletApi

----------------------------------------------------------------------------
-- The wallet API
----------------------------------------------------------------------------

servantHandlers
    :: ( MonadFullWalletWebMode ctx m
       , HasCompileInfo
       )
    => TraceNamed m
    -> ProtocolMagic
    -> TVar NtpStatus
    -> (TxAux -> m Bool)
    -> ServerT A.WalletApi m
servantHandlers logTrace pm ntpStatus submitTx = toServant' A.WalletApiRecord
    { _test        = testHandlers
    , _wallets     = walletsHandlers logTrace
    , _accounts    = accountsHandlers logTrace
    , _addresses   = addressesHandlers logTrace
    , _profile     = profileHandlers
    , _txs         = txsHandlers logTrace pm submitTx
    , _update      = updateHandlers
    , _redemptions = redemptionsHandlers logTrace pm submitTx
    , _reporting   = reportingHandlers
    , _settings    = settingsHandlers logTrace ntpStatus
    , _backup      = backupHandlers logTrace
    , _info        = infoHandlers
    , _system      = systemHandlers logTrace
    }

-- branches of the API

testHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WTestApi m
testHandlers = toServant' A.WTestApiRecord
    { _testReset = M.testResetAll
    , _testState = M.dumpState
    }

walletsHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> ServerT A.WWalletsApi m
walletsHandlers logTrace = toServant' A.WWalletsApiRecord
    { _getWallet              = M.getWallet logTrace
    , _getWallets             = M.getWallets logTrace
    , _newWallet              = M.newWallet logTrace
    , _updateWallet           = M.updateWallet logTrace
    , _restoreWallet          = M.restoreWalletFromSeed logTrace
    , _deleteWallet           = M.deleteWallet
    , _importWallet           = M.importWallet logTrace
    , _changeWalletPassphrase = M.changeWalletPassphrase
    }

accountsHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> ServerT A.WAccountsApi m
accountsHandlers logTrace = toServant' A.WAccountsApiRecord
    { _getAccount    = M.getAccount logTrace
    , _getAccounts   = M.getAccounts logTrace
    , _updateAccount = M.updateAccount logTrace
    , _newAccount    = M.newAccount logTrace RandomSeed
    , _deleteAccount = M.deleteAccount
    }

addressesHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> ServerT A.WAddressesApi m
addressesHandlers logTrace = toServant' A.WAddressesApiRecord
    { _newAddress     = M.newAddress logTrace RandomSeed
    , _isValidAddress = M.isValidAddress
    }

profileHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WProfileApi m
profileHandlers = toServant' A.WProfileApiRecord
    { _getProfile    = M.getUserProfile
    , _updateProfile = M.updateUserProfile
    }

txsHandlers
    :: MonadFullWalletWebMode ctx m
    => TraceNamed m
    -> ProtocolMagic
    -> (TxAux -> m Bool)
    -> ServerT A.WTxsApi m
txsHandlers logTrace pm submitTx = toServant' A.WTxsApiRecord
    { _newPayment                = M.newPayment logTrace pm submitTx
    , _newPaymentBatch           = M.newPaymentBatch logTrace pm submitTx
    , _txFee                     = M.getTxFee pm
    , _resetFailedPtxs           = M.resetAllFailedPtxs
    , _cancelApplyingPtxs        = M.cancelAllApplyingPtxs
    , _cancelSpecificApplyingPtx = M.cancelOneApplyingPtx
    , _getHistory                = M.getHistoryLimited logTrace
    , _pendingSummary            = M.gatherPendingTxsSummary
    }

updateHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WUpdateApi m
updateHandlers = toServant' A.WUpdateApiRecord
    { _nextUpdate     = M.nextUpdate
    , _postponeUpdate = M.postponeUpdate
    , _applyUpdate    = M.applyUpdate
    }

redemptionsHandlers
    :: MonadFullWalletWebMode ctx m
    => TraceNamed m
    -> ProtocolMagic
    -> (TxAux -> m Bool)
    -> ServerT A.WRedemptionsApi m
redemptionsHandlers logTrace pm submitTx = toServant' A.WRedemptionsApiRecord
    { _redeemADA          = M.redeemAda logTrace pm submitTx
    , _redeemADAPaperVend = M.redeemAdaPaperVend logTrace pm submitTx
    }

reportingHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WReportingApi m
reportingHandlers = toServant' A.WReportingApiRecord
    { _reportingInitialized = M.reportingInitialized
    }

settingsHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> TVar NtpStatus -> ServerT A.WSettingsApi m
settingsHandlers logTrace ntpStatus = toServant' A.WSettingsApiRecord
    { _getSlotsDuration    = blockchainSlotDuration <&> fromIntegral
    , _getVersion          = pure curSoftwareVersion
    , _getSyncProgress     = M.syncProgress logTrace
    , _localTimeDifference = fromMaybe 0 <$> M.localTimeDifference ntpStatus
    }

backupHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> ServerT A.WBackupApi m
backupHandlers logTrace = toServant' A.WBackupApiRecord
    { _importBackupJSON = M.importWalletJSON logTrace
    , _exportBackupJSON = M.exportWalletJSON
    }

infoHandlers :: (MonadFullWalletWebMode ctx m, HasCompileInfo) => ServerT A.WInfoApi m
infoHandlers = toServant' A.WInfoApiRecord
    { _getClientInfo = M.getClientInfo
    }

systemHandlers :: MonadFullWalletWebMode ctx m => TraceNamed m -> ServerT A.WSystemApi m
systemHandlers logTrace = toServant' A.WSystemApiRecord
    { _requestShutdown = M.requestShutdown logTrace
    }

----------------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------------

-- | A type-restricted synonym for 'toServant' that lets us avoid some type
-- annotations
toServant'
    :: (a ~ r (AsServerT m), GenericProduct a)
    => a -> ToServant a
toServant' = toServant
