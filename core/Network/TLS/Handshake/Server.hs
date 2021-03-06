{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
-- |
-- Module      : Network.TLS.Handshake.Server
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Handshake.Server
    ( handshakeServer
    , handshakeServerWith
    ) where

import Network.TLS.Parameters
import Network.TLS.Imports
import Network.TLS.Context.Internal
import Network.TLS.Session
import Network.TLS.Struct
import Network.TLS.Cipher
import Network.TLS.Compression
import Network.TLS.Credentials
import Network.TLS.Crypto
import Network.TLS.Extension
import Network.TLS.Util (catchException, fromJust)
import Network.TLS.IO
import Network.TLS.Types
import Network.TLS.State hiding (getNegotiatedProtocol)
import Network.TLS.Handshake.State
import Network.TLS.Handshake.Process
import Network.TLS.Handshake.Key
import Network.TLS.Measurement
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.List (intersect, any)
import qualified Data.ByteString as B
import Data.ByteString.Char8 ()
import Data.Ord (Down(..))
#if MIN_VERSION_base(4,8,0)
import Data.List (sortOn)
#else
import Data.List (sortBy)
import Data.Ord (comparing)
#endif

import Control.Monad.State.Strict

import Network.TLS.Handshake.Signature
import Network.TLS.Handshake.Common
import Network.TLS.Handshake.Certificate
import Network.TLS.X509

-- Put the server context in handshake mode.
--
-- Expect to receive as first packet a client hello handshake message
--
-- This is just a helper to pop the next message from the recv layer,
-- and call handshakeServerWith.
handshakeServer :: MonadIO m => ServerParams -> Context -> m ()
handshakeServer sparams ctx = liftIO $ do
    hss <- recvPacketHandshake ctx
    case hss of
        [ch] -> handshakeServerWith sparams ctx ch
        _    -> fail ("unexpected handshake received, excepting client hello and received " ++ show hss)

-- | Put the server context in handshake mode.
--
-- Expect a client hello message as parameter.
-- This is useful when the client hello has been already poped from the recv layer to inspect the packet.
--
-- When the function returns, a new handshake has been succesfully negociated.
-- On any error, a HandshakeFailed exception is raised.
--
-- handshake protocol (<- receiving, -> sending, [] optional):
--    (no session)           (session resumption)
--      <- client hello       <- client hello
--      -> server hello       -> server hello
--      -> [certificate]
--      -> [server key xchg]
--      -> [cert request]
--      -> hello done
--      <- [certificate]
--      <- client key xchg
--      <- [cert verify]
--      <- change cipher      -> change cipher
--      <- finish             -> finish
--      -> change cipher      <- change cipher
--      -> finish             <- finish
--
handshakeServerWith :: ServerParams -> Context -> Handshake -> IO ()
handshakeServerWith sparams ctx clientHello@(ClientHello clientVersion _ clientSession ciphers compressions exts _) = do
    -- rejecting client initiated renegotiation to prevent DOS.
    unless (supportedClientInitiatedRenegotiation (ctxSupported ctx)) $ do
        established <- ctxEstablished ctx
        eof <- ctxEOF ctx
        when (established && not eof) $
            throwCore $ Error_Protocol ("renegotiation is not allowed", False, NoRenegotiation)
    -- check if policy allow this new handshake to happens
    handshakeAuthorized <- withMeasure ctx (onNewHandshake $ serverHooks sparams)
    unless handshakeAuthorized (throwCore $ Error_HandshakePolicy "server: handshake denied")
    updateMeasure ctx incrementNbHandshakes

    -- Handle Client hello
    processHandshake ctx clientHello

    -- rejecting SSL2. RFC 6176
    when (clientVersion == SSL2) $ throwCore $ Error_Protocol ("SSL 2.0 is not supported", True, ProtocolVersion)
    -- rejecting SSL3. RFC 7568
    -- when (clientVersion == SSL3) $ throwCore $ Error_Protocol ("SSL 3.0 is not supported", True, ProtocolVersion)

    -- Fallback SCSV: RFC7507
    -- TLS_FALLBACK_SCSV: {0x56, 0x00}
    when (supportedFallbackScsv (ctxSupported ctx) &&
          (0x5600 `elem` ciphers) &&
          clientVersion /= maxBound) $
        throwCore $ Error_Protocol ("fallback is not allowed", True, InappropriateFallback)
    chosenVersion <- case findHighestVersionFrom clientVersion (supportedVersions $ ctxSupported ctx) of
                        Nothing -> throwCore $ Error_Protocol ("client version " ++ show clientVersion ++ " is not supported", True, ProtocolVersion)
                        Just v  -> return v

    -- If compression is null, commonCompressions should be [0].
    when (null commonCompressions) $ throwCore $
        Error_Protocol ("no compression in common with the client", True, HandshakeFailure)

    -- SNI (Server Name Indication)
    let serverName = case extensionLookup extensionID_ServerName exts >>= extensionDecode False of
            Just (ServerName ns) -> listToMaybe (mapMaybe toHostName ns)
                where toHostName (ServerNameHostName hostName) = Just hostName
                      toHostName (ServerNameOther _)           = Nothing
            _                    -> Nothing

    extraCreds <- (onServerNameIndication $ serverHooks sparams) serverName

    -- When selecting a cipher we must ensure that it is allowed for the
    -- TLS version but also that all its key-exchange requirements
    -- will be met.

    -- Some ciphers require a signature and a hash.  With TLS 1.2 the hash
    -- algorithm is selected from a combination of server configuration and
    -- the client "supported_signatures" extension.  So we cannot pick
    -- such a cipher if no hash is available for it.  It's best to skip this
    -- cipher and pick another one (with another key exchange).

    let possibleGroups = negotiatedGroupsInCommon ctx exts
        hasCommonGroupForECDHE = not (null possibleGroups)
        hasCommonGroup cipher =
            case cipherKeyExchange cipher of
                CipherKeyExchange_ECDHE_RSA    -> hasCommonGroupForECDHE
                CipherKeyExchange_ECDHE_ECDSA  -> hasCommonGroupForECDHE
                _                              -> True -- group not used
    let cipherAllowed cipher = case chosenVersion of
           TLS12 -> let -- Build a list of all signature algorithms with at least
                        -- one hash algorithm in common between client and server.
                        -- May contain duplicates, as it is only used for `elem`.
                        possibleHashSigAlgs = hashAndSignaturesInCommon ctx exts

                        isCommon sig = any (sig `signatureCompatible`) possibleHashSigAlgs
                        -- Check that a candidate cipher with a signature requiring
                        -- a hash will have at least one hash available.  This avoids
                        -- a failure later in 'decideHash'.
                        hasSigningRequirements =
                            case cipherKeyExchange cipher of
                                CipherKeyExchange_DHE_RSA      -> isCommon RSA
                                CipherKeyExchange_DHE_DSS      -> isCommon DSS
                                CipherKeyExchange_ECDHE_RSA    -> isCommon RSA
                                CipherKeyExchange_ECDHE_ECDSA  -> isCommon ECDSA
                                _                              -> True -- signature not used

                     in cipherAllowedForVersion chosenVersion cipher && hasSigningRequirements && hasCommonGroup cipher
           _     -> cipherAllowedForVersion chosenVersion cipher && hasCommonGroup cipher

    -- The shared cipherlist can become empty after filtering for compatible
    -- creds, check now before calling onCipherChoosing, which does not handle
    -- empty lists.
    let ciphersFilteredVersion = filter cipherAllowed (commonCiphers extraCreds)
    when (null ciphersFilteredVersion) $ throwCore $
        Error_Protocol ("no cipher in common with the client", True, HandshakeFailure)

    let usedCipher = (onCipherChoosing $ serverHooks sparams) chosenVersion ciphersFilteredVersion
        creds = extraCreds `mappend` sharedCredentials (ctxShared ctx)

    cred <- case cipherKeyExchange usedCipher of
                CipherKeyExchange_RSA       -> return $ credentialsFindForDecrypting creds
                CipherKeyExchange_DH_Anon   -> return $ Nothing
                CipherKeyExchange_DHE_RSA   -> return $ credentialsFindForSigning RSA creds
                CipherKeyExchange_DHE_DSS   -> return $ credentialsFindForSigning DSS creds
                CipherKeyExchange_ECDHE_RSA -> return $ credentialsFindForSigning RSA creds
                _                           -> throwCore $ Error_Protocol ("key exchange algorithm not implemented", True, HandshakeFailure)

    resumeSessionData <- case clientSession of
            (Session (Just clientSessionId)) ->
                let resume = liftIO $ sessionResume (sharedSessionManager $ ctxShared ctx) clientSessionId
                 in validateSession serverName <$> resume
            (Session Nothing)                -> return Nothing

    maybe (return ()) (usingState_ ctx . setClientSNI) serverName

    case extensionLookup extensionID_ApplicationLayerProtocolNegotiation exts >>= extensionDecode False of
        Just (ApplicationLayerProtocolNegotiation protos) -> usingState_ ctx $ setClientALPNSuggest protos
        _ -> return ()

    -- Currently, we don't send back EcPointFormats. In this case,
    -- the client chooses EcPointFormat_Uncompressed.
    case extensionLookup extensionID_EcPointFormats exts >>= extensionDecode False of
        Just (EcPointFormatsSupported fs) -> usingState_ ctx $ setClientEcPointFormatSuggest fs
        _ -> return ()

    doHandshake sparams cred ctx chosenVersion usedCipher usedCompression clientSession resumeSessionData exts

  where
        commonCipherIDs extra = ciphers `intersect` map cipherID (ctxCiphers ctx extra)
        commonCiphers   extra = filter (flip elem (commonCipherIDs extra) . cipherID) (ctxCiphers ctx extra)
        commonCompressions    = compressionIntersectID (supportedCompressions $ ctxSupported ctx) compressions
        usedCompression       = head commonCompressions

        validateSession _   Nothing                         = Nothing
        validateSession sni m@(Just sd)
            -- SessionData parameters are assumed to match the local server configuration
            -- so we need to compare only to ClientHello inputs.  Abbreviated handshake
            -- uses the same server_name than full handshake so the same
            -- credentials (and thus ciphers) are available.
            | clientVersion < sessionVersion sd             = Nothing
            | sessionCipher sd `notElem` ciphers            = Nothing
            | sessionCompression sd `notElem` compressions  = Nothing
            | isJust sni && sessionClientSNI sd /= sni      = Nothing
            | otherwise                                     = m


handshakeServerWith _ _ _ = throwCore $ Error_Protocol ("unexpected handshake message received in handshakeServerWith", True, HandshakeFailure)

doHandshake :: ServerParams -> Maybe Credential -> Context -> Version -> Cipher
            -> Compression -> Session -> Maybe SessionData
            -> [ExtensionRaw] -> IO ()
doHandshake sparams mcred ctx chosenVersion usedCipher usedCompression clientSession resumeSessionData exts = do
    case resumeSessionData of
        Nothing -> do
            handshakeSendServerData
            liftIO $ contextFlush ctx
            -- Receive client info until client Finished.
            recvClientData sparams ctx
            sendChangeCipherAndFinish ctx ServerRole
        Just sessionData -> do
            usingState_ ctx (setSession clientSession True)
            serverhello <- makeServerHello clientSession
            sendPacket ctx $ Handshake [serverhello]
            usingHState ctx $ setMasterSecret chosenVersion ServerRole $ sessionSecret sessionData
            sendChangeCipherAndFinish ctx ServerRole
            recvChangeCipherAndFinish ctx
    handshakeTerminate ctx
  where
        clientALPNSuggest = isJust $ extensionLookup extensionID_ApplicationLayerProtocolNegotiation exts

        applicationProtocol | clientALPNSuggest = do
            suggest <- usingState_ ctx getClientALPNSuggest
            case (onALPNClientSuggest $ serverHooks sparams, suggest) of
                (Just io, Just protos) -> do
                    proto <- liftIO $ io protos
                    usingState_ ctx $ do
                        setExtensionALPN True
                        setNegotiatedProtocol proto
                    return [ ExtensionRaw extensionID_ApplicationLayerProtocolNegotiation
                                            (extensionEncode $ ApplicationLayerProtocolNegotiation [proto]) ]
                (_, _)                  -> return []
             | otherwise = return []

        ---
        -- When the client sends a certificate, check whether
        -- it is acceptable for the application.
        --
        ---
        makeServerHello session = do
            srand <- ServerRandom <$> getStateRNG ctx 32
            case mcred of
                Just (_, privkey) -> usingHState ctx $ setPrivateKey privkey
                _                 -> return () -- return a sensible error

            -- in TLS12, we need to check as well the certificates we are sending if they have in the extension
            -- the necessary bits set.
            secReneg   <- usingState_ ctx getSecureRenegotiation
            secRengExt <- if secReneg
                    then do
                            vf <- usingState_ ctx $ do
                                    cvf <- getVerifiedData ClientRole
                                    svf <- getVerifiedData ServerRole
                                    return $ extensionEncode (SecureRenegotiation cvf $ Just svf)
                            return [ ExtensionRaw extensionID_SecureRenegotiation vf ]
                    else return []
            protoExt <- applicationProtocol
            sniExt   <- do
                resuming <- usingState_ ctx isSessionResuming
                if resuming
                  then return []
                  else do
                    msni <- usingState_ ctx getClientSNI
                    case msni of
                      -- RFC6066: In this event, the server SHALL include
                      -- an extension of type "server_name" in the
                      -- (extended) server hello. The "extension_data"
                      -- field of this extension SHALL be empty.
                      Just _  -> return [ ExtensionRaw extensionID_ServerName ""]
                      Nothing -> return []
            let extensions = secRengExt ++ protoExt ++ sniExt
            usingState_ ctx (setVersion chosenVersion)
            usingHState ctx $ setServerHelloParameters chosenVersion srand usedCipher usedCompression
            return $ ServerHello chosenVersion srand session (cipherID usedCipher)
                                               (compressionID usedCompression) extensions

        handshakeSendServerData = do
            serverSession <- newSession ctx
            usingState_ ctx (setSession serverSession False)
            serverhello   <- makeServerHello serverSession
            -- send ServerHello & Certificate & ServerKeyXchg & CertReq
            let certMsg = case mcred of
                            Just (srvCerts, _) -> Certificates srvCerts
                            _                  -> Certificates $ CertificateChain []
            sendPacket ctx $ Handshake [ serverhello, certMsg ]

            -- send server key exchange if needed
            skx <- case cipherKeyExchange usedCipher of
                        CipherKeyExchange_DH_Anon -> Just <$> generateSKX_DH_Anon
                        CipherKeyExchange_DHE_RSA -> Just <$> generateSKX_DHE RSA
                        CipherKeyExchange_DHE_DSS -> Just <$> generateSKX_DHE DSS
                        CipherKeyExchange_ECDHE_RSA -> Just <$> generateSKX_ECDHE RSA
                        _                         -> return Nothing
            maybe (return ()) (sendPacket ctx . Handshake . (:[]) . ServerKeyXchg) skx

            -- FIXME we don't do this on a Anonymous server

            -- When configured, send a certificate request
            -- with the DNs of all confgure CA
            -- certificates.
            --
            when (serverWantClientCert sparams) $ do
                usedVersion <- usingState_ ctx getVersion
                let certTypes = [ CertificateType_RSA_Sign ]
                    hashSigs = if usedVersion < TLS12
                                   then Nothing
                                   else Just (supportedHashSignatures $ ctxSupported ctx)
                    creq = CertRequest certTypes hashSigs
                               (map extractCAname $ serverCACertificates sparams)
                usingHState ctx $ setCertReqSent True
                sendPacket ctx (Handshake [creq])

            -- Send HelloDone
            sendPacket ctx (Handshake [ServerHelloDone])

        extractCAname :: SignedCertificate -> DistinguishedName
        extractCAname cert = certSubjectDN $ getCertificate cert

        setup_DHE = do
            let dhparams = fromJust "server DHE Params" $ serverDHEParams sparams
            (priv, pub) <- generateDHE ctx dhparams

            let serverParams = serverDHParamsFrom dhparams pub

            usingHState ctx $ setServerDHParams serverParams
            usingHState ctx $ setDHPrivate priv
            return serverParams

        -- Choosing a hash algorithm to sign (EC)DHE parameters
        -- in ServerKeyExchange. Hash algorithm is not suggested by
        -- the chosen cipher suite. So, it should be selected based on
        -- the "signature_algorithms" extension in a client hello.
        -- If RSA is also used for key exchange, this function is
        -- not called.
        decideHashSig sigAlg = do
            usedVersion <- usingState_ ctx getVersion
            case usedVersion of
              TLS12 -> do
                  let hashSigs = hashAndSignaturesInCommon ctx exts
                  case filter (sigAlg `signatureCompatible`) hashSigs of
                      []  -> error ("no hash signature for " ++ show sigAlg)
                      x:_ -> return $ Just x
              _     -> return Nothing

        generateSKX_DHE sigAlg = do
            serverParams  <- setup_DHE
            mhashSig <- decideHashSig sigAlg
            signed <- digitallySignDHParams ctx serverParams sigAlg mhashSig
            case sigAlg of
                RSA -> return $ SKX_DHE_RSA serverParams signed
                DSS -> return $ SKX_DHE_DSS serverParams signed
                _   -> error ("generate skx_dhe unsupported signature type: " ++ show sigAlg)

        generateSKX_DH_Anon = SKX_DH_Anon <$> setup_DHE

        setup_ECDHE grp = do
            (srvpri, srvpub) <- generateECDHE ctx grp
            let serverParams = ServerECDHParams grp srvpub
            usingHState ctx $ setServerECDHParams serverParams
            usingHState ctx $ setECDHPrivate srvpri
            return serverParams

        generateSKX_ECDHE sigAlg = do
            let possibleGroups = negotiatedGroupsInCommon ctx exts
            grp <- case possibleGroups of
                     []  -> throwCore $ Error_Protocol ("no common group", True, HandshakeFailure)
                     g:_ -> return g
            serverParams <- setup_ECDHE grp
            mhashSig <- decideHashSig sigAlg
            signed <- digitallySignECDHParams ctx serverParams sigAlg mhashSig
            case sigAlg of
                RSA -> return $ SKX_ECDHE_RSA serverParams signed
                _   -> error ("generate skx_ecdhe unsupported signature type: " ++ show sigAlg)

        -- create a DigitallySigned objects for DHParams or ECDHParams.

-- | receive Client data in handshake until the Finished handshake.
--
--      <- [certificate]
--      <- client key xchg
--      <- [cert verify]
--      <- change cipher
--      <- finish
--
recvClientData :: ServerParams -> Context -> IO ()
recvClientData sparams ctx = runRecvState ctx (RecvStateHandshake processClientCertificate)
  where processClientCertificate (Certificates certs) = do
            -- run certificate recv hook
            ctxWithHooks ctx (\hooks -> hookRecvCertificates hooks certs)
            -- Call application callback to see whether the
            -- certificate chain is acceptable.
            --
            usage <- liftIO $ catchException (onClientCertificate (serverHooks sparams) certs) rejectOnException
            case usage of
                CertificateUsageAccept        -> return ()
                CertificateUsageReject reason -> certificateRejected reason

            -- Remember cert chain for later use.
            --
            usingHState ctx $ setClientCertChain certs

            -- FIXME: We should check whether the certificate
            -- matches our request and that we support
            -- verifying with that certificate.

            return $ RecvStateHandshake processClientKeyExchange

        processClientCertificate p = processClientKeyExchange p

        -- cannot use RecvStateHandshake, as the next message could be a ChangeCipher,
        -- so we must process any packet, and in case of handshake call processHandshake manually.
        processClientKeyExchange (ClientKeyXchg _) = return $ RecvStateNext processCertificateVerify
        processClientKeyExchange p                 = unexpected (show p) (Just "client key exchange")

        -- Check whether the client correctly signed the handshake.
        -- If not, ask the application on how to proceed.
        --
        processCertificateVerify (Handshake [hs@(CertVerify dsig)]) = do
            processHandshake ctx hs

            checkValidClientCertChain "change cipher message expected"

            usedVersion <- usingState_ ctx getVersion
            -- Fetch all handshake messages up to now.
            msgs  <- usingHState ctx $ B.concat <$> getHandshakeMessages

            sigAlgExpected <- getRemoteSignatureAlg

            -- FIXME should check certificate is allowed for signing

            verif <- checkCertificateVerify ctx usedVersion sigAlgExpected msgs dsig

            case verif of
                True -> do
                    -- When verification succeeds, commit the
                    -- client certificate chain to the context.
                    --
                    Just certs <- usingHState ctx getClientCertChain
                    usingState_ ctx $ setClientCertificateChain certs
                    return ()

                False -> do
                    -- Either verification failed because of an
                    -- invalid format (with an error message), or
                    -- the signature is wrong.  In either case,
                    -- ask the application if it wants to
                    -- proceed, we will do that.
                    res <- liftIO $ onUnverifiedClientCert (serverHooks sparams)
                    if res
                        then do
                            -- When verification fails, but the
                            -- application callbacks accepts, we
                            -- also commit the client certificate
                            -- chain to the context.
                            Just certs <- usingHState ctx getClientCertChain
                            usingState_ ctx $ setClientCertificateChain certs
                        else throwCore $ Error_Protocol ("verification failed", True, BadCertificate)
            return $ RecvStateNext expectChangeCipher

        processCertificateVerify p = do
            chain <- usingHState ctx getClientCertChain
            case chain of
                Just cc | isNullCertificateChain cc -> return ()
                        | otherwise                 -> throwCore $ Error_Protocol ("cert verify message missing", True, UnexpectedMessage)
                Nothing -> return ()
            expectChangeCipher p

        getRemoteSignatureAlg = do
            pk <- usingHState ctx getRemotePublicKey
            case pk of
                PubKeyRSA _   -> return RSA
                PubKeyDSA _   -> return DSS
                PubKeyEC  _   -> return ECDSA
                _             -> throwCore $ Error_Protocol ("unsupported remote public key type", True, HandshakeFailure)

        expectChangeCipher ChangeCipherSpec = do
            return $ RecvStateHandshake $ expectFinish

        expectChangeCipher p                = unexpected (show p) (Just "change cipher")

        expectFinish (Finished _) = return RecvStateDone
        expectFinish p            = unexpected (show p) (Just "Handshake Finished")

        checkValidClientCertChain msg = do
            chain <- usingHState ctx getClientCertChain
            let throwerror = Error_Protocol (msg , True, UnexpectedMessage)
            case chain of
                Nothing -> throwCore throwerror
                Just cc | isNullCertificateChain cc -> throwCore throwerror
                        | otherwise                 -> return ()

hashAndSignaturesInCommon :: Context -> [ExtensionRaw] -> [HashAndSignatureAlgorithm]
hashAndSignaturesInCommon ctx exts =
    let cHashSigs = case extensionLookup extensionID_SignatureAlgorithms exts >>= extensionDecode False of
            -- See Section 7.4.1.4.1 of RFC 5246.
            Nothing -> [(HashSHA1, SignatureECDSA)
                       ,(HashSHA1, SignatureRSA)
                       ,(HashSHA1, SignatureDSS)]
            Just (SignatureAlgorithms sas) -> sas
        sHashSigs = supportedHashSignatures $ ctxSupported ctx
        -- The values in the "signature_algorithms" extension
        -- are in descending order of preference.
        -- However here the algorithms are selected according
        -- to server preference in 'supportedHashSignatures'.
     in sHashSigs `intersect` cHashSigs

negotiatedGroupsInCommon :: Context -> [ExtensionRaw] -> [Group]
negotiatedGroupsInCommon ctx exts = case extensionLookup extensionID_NegotiatedGroups exts >>= extensionDecode False of
    Just (NegotiatedGroups clientGroups) ->
        let serverGroups = supportedGroups (ctxSupported ctx) `intersect` availableGroups
        in serverGroups `intersect` clientGroups
    _                                    -> []

findHighestVersionFrom :: Version -> [Version] -> Maybe Version
findHighestVersionFrom clientVersion allowedVersions =
    case filter (clientVersion >=) $ sortOn Down allowedVersions of
        []  -> Nothing
        v:_ -> Just v

#if !MIN_VERSION_base(4,8,0)
sortOn :: Ord b => (a -> b) -> [a] -> [a]
sortOn f =
  map snd . sortBy (comparing fst) . map (\x -> let y = f x in y `seq` (y, x))
#endif
