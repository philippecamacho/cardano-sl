{-# LANGUAGE TypeFamilies #-}

-- | Core types of SSC.

module Pos.Core.Ssc
       (
       -- * Commitments
         Commitment (..)
       , getCommShares
       , CommitmentSignature
       , SignedCommitment
       , CommitmentsMap (getCommitmentsMap)
       , mkCommitmentsMap
       , mkCommitmentsMapUnsafe

       -- * Openings
       , Opening (..)
       , OpeningsMap

       -- * Shares
       , InnerSharesMap
       , SharesMap
       , SharesDistribution

       -- * Payload and proof
       , VssCertificatesHash
       , SscPayload (..)
       , SscProof (..)
       , mkSscProof

       -- * Misc
       , NodeSet
       ) where

import           Universum

import           Control.Lens (each, traverseOf)
import           Data.Hashable (Hashable)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text.Buildable
import           Data.Text.Lazy.Builder (Builder)
import           Fmt (genericF)
import           Formatting (Format, bprint, build, int, (%))
import           Serokell.Util (listJson)

import           Pos.Binary.Class (AsBinary (..), Bi (..), fromBinaryM, serialize')
import           Pos.Core.Address (addressHash)
import           Pos.Core.Configuration (HasConfiguration)
import           Pos.Core.Types (EpochIndex, StakeholderId)
import           Pos.Core.Vss (VssCertificate, VssCertificatesMap (..), vcExpiryEpoch)
import           Pos.Crypto (DecShare, EncShare, Hash, PublicKey, Secret, SecretProof, Signature,
                             VssPublicKey, hash, shortHashF)

type NodeSet = HashSet StakeholderId

----------------------------------------------------------------------------
-- Commitments
----------------------------------------------------------------------------

-- | Commitment is a message generated during the first stage of SSC.
-- It contains encrypted shares and proof of secret.
--
-- There can be more than one share generated for a single participant.
data Commitment = Commitment
    { commProof  :: !SecretProof
    , commShares :: !(HashMap (AsBinary VssPublicKey)
                              (NonEmpty (AsBinary EncShare)))
    } deriving (Show, Eq, Generic)

instance NFData Commitment
instance Hashable Commitment

-- | Get commitment shares.
getCommShares :: Commitment -> Maybe [(VssPublicKey, NonEmpty EncShare)]
getCommShares =
    traverseOf (each . _1) fromBinaryM <=<          -- decode keys
    traverseOf (each . _2 . each) fromBinaryM .     -- decode shares
    HM.toList . commShares

instance Ord Commitment where
    compare = comparing (serialize' . commProof) <>
              comparing (sort . HM.toList . commShares)

-- | Signature which ensures that commitment was generated by node
-- with given public key for given epoch.
type CommitmentSignature = Signature (EpochIndex, Commitment)

type SignedCommitment = (PublicKey, Commitment, CommitmentSignature)

-- | 'CommitmentsMap' is a wrapper for 'HashMap StakeholderId SignedCommitment'
-- which ensures that keys are consistent with values, i. e. 'PublicKey'
-- from 'SignedCommitment' corresponds to key which is 'StakeholderId'.
newtype CommitmentsMap = CommitmentsMap
    { getCommitmentsMap :: HashMap StakeholderId SignedCommitment
    } deriving (Generic, Semigroup, Monoid, Show, Eq, Container, NFData)

type instance Element CommitmentsMap = SignedCommitment

-- | Safe constructor of 'CommitmentsMap'.
mkCommitmentsMap :: [SignedCommitment] -> CommitmentsMap
mkCommitmentsMap = CommitmentsMap . HM.fromList . map toCommPair
  where
    toCommPair signedComm@(pk, _, _) = (addressHash pk, signedComm)

-- | Unsafe straightforward constructor of 'CommitmentsMap'.
mkCommitmentsMapUnsafe :: HashMap StakeholderId SignedCommitment
                       -> CommitmentsMap
mkCommitmentsMapUnsafe = CommitmentsMap

----------------------------------------------------------------------------
-- Openings
----------------------------------------------------------------------------

-- | Opening reveals secret.
newtype Opening = Opening
    { getOpening :: AsBinary Secret
    } deriving (Show, Eq, Generic, Buildable, NFData)

type OpeningsMap = HashMap StakeholderId Opening

----------------------------------------------------------------------------
-- Shares
----------------------------------------------------------------------------

-- | Each node generates several 'SharedSeed's, breaks every
-- 'SharedSeed' into 'Share's, and sends those encrypted shares to
-- other nodes (for i-th commitment at i-th element of NonEmpty
-- list). Then those shares are decrypted.
type InnerSharesMap = HashMap StakeholderId (NonEmpty (AsBinary DecShare))

-- | In a 'SharesMap', for each node we collect shares which said node
-- has received and decrypted:
--
--   * Outer key = who decrypted the share
--   * Inner key = who created the share
--
-- Let's say that there are participants {A, B, C}. If A has generated a
-- secret and shared it, A's shares will be denoted as Aa, Ab and Ac (sent
-- correspondingly to A itself, B and C). Then node B will decrypt its share
-- and get Ab_dec; same for other nodes and participants. In the end, after
-- the second phase of the protocol completes and we gather everyone's
-- shares, we'll get the following map:
--
-- @
-- { A: {A: Aa_dec, B: Ba_dec, C: Ca_dec}
-- , B: {A: Ab_dec, B: Bb_dec, C: Cb_dec}
-- , C: {A: Ac_dec, B: Bc_dec, C: Cc_dec}
-- }
-- @
--
-- (Here there's only one share per node, but in reality there'll be more.)
type SharesMap = HashMap StakeholderId InnerSharesMap

-- | This maps shareholders to amount of shares she should issue. Depends on
-- the stake distribution.
type SharesDistribution = HashMap StakeholderId Word16

instance Buildable (StakeholderId, Word16) where
    build (id, c) = bprint ("("%build%": "%build%" shares)") id c

----------------------------------------------------------------------------
-- Payload and proof
----------------------------------------------------------------------------

-- | Payload included into blocks.
data SscPayload
    = CommitmentsPayload
        { spComms :: !CommitmentsMap
        , spVss   :: !VssCertificatesMap }
    | OpeningsPayload
        { spOpenings :: !OpeningsMap
        , spVss      :: !VssCertificatesMap }
    | SharesPayload
        { spShares :: !SharesMap
        , spVss    :: !VssCertificatesMap }
    | CertificatesPayload
        { spVss    :: !VssCertificatesMap }
    deriving (Eq, Show, Generic)

-- Note: we can't use 'VssCertificatesMap', because we serialize it as
-- a 'HashSet', but in the very first version of mainnet this map was
-- serialized as a 'HashMap' (and 'VssCertificatesMap' was just a type
-- alias for that 'HashMap').
--
-- Alternative approach would be to keep 'instance Bi VssCertificatesMap'
-- the same as it was in mainnet.
type VssCertificatesHash = Hash (HashMap StakeholderId VssCertificate)

-- | Proof that SSC payload is correct (it's included into block header)
data SscProof
    = CommitmentsProof
        { sprComms :: !(Hash CommitmentsMap)
        , sprVss   :: !VssCertificatesHash }
    | OpeningsProof
        { sprOpenings :: !(Hash OpeningsMap)
        , sprVss      :: !VssCertificatesHash }
    | SharesProof
        { sprShares :: !(Hash SharesMap)
        , sprVss    :: !VssCertificatesHash }
    | CertificatesProof
        { sprVss    :: !VssCertificatesHash }
    deriving (Eq, Show, Generic)

instance Buildable SscProof where
    build = genericF

instance NFData SscPayload
instance NFData SscProof

-- | Create proof (for inclusion into block header) from 'SscPayload'.
mkSscProof
    :: ( HasConfiguration
       , Bi VssCertificatesMap
       , Bi CommitmentsMap
       , Bi Opening
       , Bi VssCertificate
       ) => SscPayload -> SscProof
mkSscProof payload =
    case payload of
        CommitmentsPayload comms certs ->
            proof CommitmentsProof comms certs
        OpeningsPayload openings certs ->
            proof OpeningsProof openings certs
        SharesPayload shares certs     ->
            proof SharesProof shares certs
        CertificatesPayload certs      ->
            CertificatesProof (hash $ getVssCertificatesMap certs)
  where
    proof constr hm (getVssCertificatesMap -> certs) =
        constr (hash hm) (hash certs)


isEmptySscPayload :: SscPayload -> Bool
isEmptySscPayload (CommitmentsPayload comms certs) = null comms && null certs
isEmptySscPayload (OpeningsPayload opens certs)    = null opens && null certs
isEmptySscPayload (SharesPayload shares certs)     = null shares && null certs
isEmptySscPayload (CertificatesPayload certs)      = null certs

instance Buildable SscPayload where
    build gp
        | isEmptySscPayload gp = "  no SSC payload"
        | otherwise =
            case gp of
                CommitmentsPayload comms certs ->
                    formatTwo formatCommitments comms certs
                OpeningsPayload openings certs ->
                    formatTwo formatOpenings openings certs
                SharesPayload shares certs ->
                    formatTwo formatShares shares certs
                CertificatesPayload certs -> formatCertificates certs
      where
        formatIfNotNull
            :: Container c
            => Format Builder (c -> Builder) -> c -> Builder
        formatIfNotNull formatter l
            | null l = mempty
            | otherwise = bprint formatter l
        formatCommitments (getCommitmentsMap -> comms) =
            formatIfNotNull
                ("  commitments from: " %listJson % "\n")
                (HM.keys comms)
        formatOpenings openings =
            formatIfNotNull
                ("  openings from: " %listJson % "\n")
                (HM.keys openings)
        formatShares shares =
            formatIfNotNull
                ("  shares from: " %listJson % "\n")
                (HM.keys shares)
        formatCertificates (getVssCertificatesMap -> certs) =
            formatIfNotNull
                ("  certificates from: " %listJson % "\n")
                (map formatVssCert $ HM.toList certs)
        formatVssCert (id, cert) =
            bprint (shortHashF%":"%int) id (vcExpiryEpoch cert)
        formatTwo formatter hm certs =
            mconcat [formatter hm, formatCertificates certs]
