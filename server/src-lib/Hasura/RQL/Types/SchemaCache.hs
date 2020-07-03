-- As of GHC 8.6, a use of DefaultSignatures in this module triggers a false positive for this
-- warning, so don’t treat it as an error even if -Werror is enabled.
{-# OPTIONS_GHC -Wwarn=redundant-constraints #-}

{-# LANGUAGE UndecidableInstances #-}

module Hasura.RQL.Types.SchemaCache
  ( SchemaCache(..)
  , SchemaCacheVer
  , initSchemaCacheVer
  , incSchemaCacheVer
  , TableConfig(..)
  , emptyTableConfig

  , TableCoreCache
  , TableCache
  , ActionCache

  -- , OutputFieldTypeInfo(..)
  -- , AnnotatedObjectType(..)
  -- , AnnotatedObjects
  , TypeRelationship(..)
  , trName, trType, trRemoteTable, trFieldMapping
  -- , NonObjectTypeMap(..)
  , TableCoreInfoG(..)
  , TableRawInfo
  , TableCoreInfo
  , tciName
  , tciDescription
  , tciSystemDefined
  , tciFieldInfoMap
  , tciPrimaryKey
  , tciUniqueConstraints
  , tciForeignKeys
  , tciViewInfo
  , tciEnumValues
  , tciCustomConfig
  , tciUniqueOrPrimaryKeyConstraints

  , TableInfo(..)
  , tiCoreInfo
  , tiRolePermInfoMap
  , tiEventTriggerInfoMap

  , ViewInfo(..)
  , isMutable
  , mutableView

  , IntrospectionResult
  , RemoteSchemaCtx(..)
  , RemoteSchemaMap

  , DepMap
  , WithDeps

  , TableCoreInfoRM(..)
  , TableCoreCacheRT(..)
  , CacheRM(..)
  , CacheRT(..)

  , FieldInfoMap
  , FieldInfo(..)
  , _FIColumn
  , _FIRelationship
  , _FIComputedField
  , fieldInfoName
  , fieldInfoGraphQLNames
  , getCols
  , getRels
  , getComputedFieldInfos

  , isPGColInfo
  , RelInfo(..)

  , RolePermInfo(..)
  , mkRolePermInfo
  , permIns
  , permSel
  , permUpd
  , permDel
  , PermAccessor(..)
  , permAccToLens
  , permAccToType
  , withPermType
  , RolePermInfoMap

  , InsPermInfo(..)
  , SelPermInfo(..)
  , getSelectPermissionInfoM
  , UpdPermInfo(..)
  , DelPermInfo(..)
  , PreSetColsPartial

  , EventTriggerInfo(..)
  , EventTriggerInfoMap

  , TableObjId(..)
  , SchemaObjId(..)
  , reportSchemaObj
  , reportSchemaObjs
  , DependencyReason(..)
  , SchemaDependency(..)
  , mkParentDep
  , mkColDep
  , mkComputedFieldDep
  , getDependentObjs
  , getDependentObjsWith

  , FunctionType(..)
  , FunctionArg(..)
  , FunctionArgName(..)
  , FunctionName(..)
  , FunctionInfo(..)
  , FunctionCache
  , getFuncsOfTable
  , askFunctionInfo
  ) where

import           Hasura.Db
import           Hasura.GraphQL.Context            (GQLContext)
import           Hasura.Incremental                (Dependency, MonadDepend (..), selectKeyD)
import           Hasura.Prelude
import           Hasura.RQL.Types.Action
import           Hasura.RQL.Types.BoolExp
import           Hasura.RQL.Types.Common
import           Hasura.RQL.Types.ComputedField
import           Hasura.RQL.Types.CustomTypes
import           Hasura.RQL.Types.Error
import           Hasura.RQL.Types.Function
import           Hasura.RQL.Types.Metadata
import           Hasura.RQL.Types.Permission
import           Hasura.RQL.Types.QueryCollection
import           Hasura.RQL.Types.RemoteSchema
import           Hasura.RQL.Types.SchemaCacheTypes
import           Hasura.RQL.Types.Table
import           Hasura.SQL.Types
import           Hasura.Session

import           Data.Aeson
import           Data.Aeson.Casing
import           Data.Aeson.TH

import qualified Data.HashMap.Strict               as M
import qualified Data.HashSet                      as HS
import qualified Data.Text                         as T
import qualified Language.GraphQL.Draft.Syntax     as G

reportSchemaObjs :: [SchemaObjId] -> T.Text
reportSchemaObjs = T.intercalate ", " . sort . map reportSchemaObj

mkParentDep :: QualifiedTable -> SchemaDependency
mkParentDep tn = SchemaDependency (SOTable tn) DRTable

mkColDep :: DependencyReason -> QualifiedTable -> PGCol -> SchemaDependency
mkColDep reason tn col =
  flip SchemaDependency reason . SOTableObj tn $ TOCol col

mkComputedFieldDep
  :: DependencyReason -> QualifiedTable -> ComputedFieldName -> SchemaDependency
mkComputedFieldDep reason tn computedField =
  flip SchemaDependency reason . SOTableObj tn $ TOComputedField computedField

type WithDeps a = (a, [SchemaDependency])

type IntrospectionResult = ( G.SchemaDocument
                           , G.Name -- query_root
                           , Maybe G.Name -- mutation_root
                           , Maybe G.Name
                           )

data RemoteSchemaCtx
  = RemoteSchemaCtx
  { rscName  :: !RemoteSchemaName
  , rscIntro :: !IntrospectionResult
  , rscInfo  :: !RemoteSchemaInfo
  } deriving (Show, Eq)

instance ToJSON RemoteSchemaCtx where
  toJSON = toJSON . rscInfo

type RemoteSchemaMap = M.HashMap RemoteSchemaName RemoteSchemaCtx

type DepMap = M.HashMap SchemaObjId (HS.HashSet SchemaDependency)

newtype SchemaCacheVer
  = SchemaCacheVer { unSchemaCacheVer :: Word64 }
  deriving (Show, Eq, Ord, Hashable, ToJSON, FromJSON)

initSchemaCacheVer :: SchemaCacheVer
initSchemaCacheVer = SchemaCacheVer 0

incSchemaCacheVer :: SchemaCacheVer -> SchemaCacheVer
incSchemaCacheVer (SchemaCacheVer prev) =
  SchemaCacheVer $ prev + 1

type FunctionCache = M.HashMap QualifiedFunction FunctionInfo -- info of all functions
type ActionCache = M.HashMap ActionName ActionInfo -- info of all actions

data SchemaCache
  = SchemaCache
  { scTables           :: !TableCache
  , scActions          :: !ActionCache
  , scFunctions        :: !FunctionCache
  , scRemoteSchemas    :: !RemoteSchemaMap
  , scAllowlist        :: !(HS.HashSet GQLQuery)
  , scGQLContext       :: !(HashMap RoleName GQLContext)
  , scUnauthenticatedGQLContext :: !GQLContext
  , scRelayContext     :: !(HashMap RoleName GQLContext)
  , scUnauthenticatedRelayContext :: !GQLContext
  -- , scCustomTypes       :: !(NonObjectTypeMap, AnnotatedObjects)
  , scDepMap           :: !DepMap
  , scInconsistentObjs :: ![InconsistentMetadata]
  }
$(deriveToJSON (aesonDrop 2 snakeCase) ''SchemaCache)

getFuncsOfTable :: QualifiedTable -> FunctionCache -> [FunctionInfo]
getFuncsOfTable qt fc = flip filter allFuncs $ \f -> qt == fiReturnType f
  where
    allFuncs = M.elems fc

-- | A more limited version of 'CacheRM' that is used when building the schema cache, since the
-- entire schema cache has not been built yet.
class (Monad m) => TableCoreInfoRM m where
  lookupTableCoreInfo :: QualifiedTable -> m (Maybe TableCoreInfo)
  default lookupTableCoreInfo :: (CacheRM m) => QualifiedTable -> m (Maybe TableCoreInfo)
  lookupTableCoreInfo tableName = fmap _tiCoreInfo . M.lookup tableName . scTables <$> askSchemaCache

instance (TableCoreInfoRM m) => TableCoreInfoRM (ReaderT r m) where
  lookupTableCoreInfo = lift . lookupTableCoreInfo
instance (TableCoreInfoRM m) => TableCoreInfoRM (StateT s m) where
  lookupTableCoreInfo = lift . lookupTableCoreInfo
instance (Monoid w, TableCoreInfoRM m) => TableCoreInfoRM (WriterT w m) where
  lookupTableCoreInfo = lift . lookupTableCoreInfo

newtype TableCoreCacheRT m a
  = TableCoreCacheRT { runTableCoreCacheRT :: Dependency TableCoreCache -> m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadError e, MonadState s, MonadWriter w, MonadTx)
    via (ReaderT (Dependency TableCoreCache) m)
  deriving (MonadTrans) via (ReaderT (Dependency TableCoreCache))

instance (MonadReader r m) => MonadReader r (TableCoreCacheRT m) where
  ask = lift ask
  local f m = TableCoreCacheRT (local f . runTableCoreCacheRT m)
instance (MonadDepend m) => TableCoreInfoRM (TableCoreCacheRT m) where
  lookupTableCoreInfo tableName = TableCoreCacheRT (dependOnM . selectKeyD tableName)

class (TableCoreInfoRM m) => CacheRM m where
  askSchemaCache :: m SchemaCache

instance (CacheRM m) => CacheRM (ReaderT r m) where
  askSchemaCache = lift askSchemaCache
instance (CacheRM m) => CacheRM (StateT s m) where
  askSchemaCache = lift askSchemaCache
instance (Monoid w, CacheRM m) => CacheRM (WriterT w m) where
  askSchemaCache = lift askSchemaCache

newtype CacheRT m a = CacheRT { runCacheRT :: SchemaCache -> m a }
  deriving (Functor, Applicative, Monad, MonadError e, MonadWriter w) via (ReaderT SchemaCache m)
  deriving (MonadTrans) via (ReaderT SchemaCache)
instance (Monad m) => TableCoreInfoRM (CacheRT m)
instance (Monad m) => CacheRM (CacheRT m) where
  askSchemaCache = CacheRT pure

askFunctionInfo
  :: (CacheRM m, QErrM m)
  => QualifiedFunction ->  m FunctionInfo
askFunctionInfo qf = do
  sc <- askSchemaCache
  maybe throwNoFn return $ M.lookup qf $ scFunctions sc
  where
    throwNoFn = throw400 NotExists $
      "function not found in cache " <>> qf

getDependentObjs :: SchemaCache -> SchemaObjId -> [SchemaObjId]
getDependentObjs = getDependentObjsWith (const True)

getDependentObjsWith
  :: (DependencyReason -> Bool) -> SchemaCache -> SchemaObjId -> [SchemaObjId]
getDependentObjsWith f sc objId =
  -- [ sdObjId sd | sd <- filter (f . sdReason) allDeps]
  map fst $ filter (isDependency . snd) $ M.toList $ scDepMap sc
  where
    isDependency deps = not $ HS.null $ flip HS.filter deps $
      \(SchemaDependency depId reason) -> objId `induces` depId && f reason
    -- induces a b : is b dependent on a
    induces (SOTable tn1) (SOTable tn2)      = tn1 == tn2
    induces (SOTable tn1) (SOTableObj tn2 _) = tn1 == tn2
    induces objId1 objId2                    = objId1 == objId2
    -- allDeps = toList $ fromMaybe HS.empty $ M.lookup objId $ scDepMap sc
