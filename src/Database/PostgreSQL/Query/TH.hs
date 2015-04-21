module Database.PostgreSQL.Query.TH
       ( -- * Deriving instances
         deriveFromRow
       , deriveToRow
       , deriveEntity
       , EntityOptions(..)
         -- * Embedding sql files
       , embedSql
       , sqlFile
         -- * Sql string interpolation
       , sqlExp
       , sqlExpEmbed
       , sqlExpFile
       ) where

import Prelude

import Control.Applicative
import Data.Default
import Data.FileEmbed ( embedFile )
import Database.PostgreSQL.Query.Entity ( Entity(..) )
import Database.PostgreSQL.Query.TH.SqlExp
import Database.PostgreSQL.Simple.FromRow ( FromRow(..), field )
import Database.PostgreSQL.Simple.ToRow ( ToRow(..) )
import Database.PostgreSQL.Simple.Types ( Query(..) )
import Language.Haskell.TH

-- | Return constructor name
cName :: (Monad m) => Con -> m Name
cName (NormalC n _) = return n
cName (RecC n _) = return n
cName _ = error "Constructor must be simple"

-- | Return count of constructor fields
cArgs :: (Monad m) => Con -> m Int
cArgs (NormalC _ n) = return $ length n
cArgs (RecC _ n) = return $ length n
cArgs _ = error "Constructor must be simple"

cFieldNames :: Con -> [Name]
cFieldNames (RecC _ vst) = map (\(a, _, _) -> a) vst
cFieldNames _ = error "Constructor must be a record (product type with field names)"

-- | Derive 'FromRow' instance. i.e. you have type like that
--
-- @
-- data Entity = Entity
--               { eField :: Text
--               , eField2 :: Int
--               , efield3 :: Bool }
-- @
--
-- then 'deriveFromRow' will generate this instance:
-- instance FromRow Entity where
--
-- @
-- instance FromRow Entity where
--     fromRow = Entity
--               \<$> field
--               \<*> field
--               \<*> field
-- @
--
-- Datatype must have just one constructor with arbitrary count of fields
deriveFromRow :: Name -> Q [Dec]
deriveFromRow t = do
    TyConI (DataD _ _ _ [con] _) <- reify t
    cname <- cName con
    cargs <- cArgs con
    [d|instance FromRow $(return $ ConT t) where
           fromRow = $(fieldsQ cname cargs)|]
  where
    fieldsQ cname cargs = do
        fld <- [| field |]
        fmp <- [| (<$>) |]
        fap <- [| (<*>) |]
        return $ UInfixE (ConE cname) fmp (fapChain cargs fld fap)

    fapChain 0 _ _ = error "there must be at least 1 field in constructor"
    fapChain 1 fld _ = fld
    fapChain n fld fap = UInfixE fld fap (fapChain (n-1) fld fap)

lookupVNameErr :: String -> Q Name
lookupVNameErr name =
    lookupValueName name >>=
    maybe (error $ "could not find identifier: " ++ name)
          return


-- | derives 'ToRow' instance for datatype like
--
-- @
-- data Entity = Entity
--               { eField :: Text
--               , eField2 :: Int
--               , efield3 :: Bool }
-- @
--
-- it will derive instance like that:
--
-- @
-- instance ToRow Entity where
--      toRow (Entity e1 e2 e3) =
--          [ toField e1
--          , toField e2
--          , toField e3 ]
-- @
deriveToRow :: Name -> Q [Dec]
deriveToRow t = do
    TyConI (DataD _ _ _ [con] _) <- reify t
    cname <- cName con
    cargs <- cArgs con
    cvars <- sequence
             $ replicate cargs
             $ newName "a"
    [d|instance ToRow $(return $ ConT t) where
           toRow $(return $ ConP cname $ map VarP cvars) = $(toFields cvars)|]
  where
    toFields v = do
        tof <- lookupVNameErr "toField"
        return $ ListE
            $ map
            (\e -> AppE (VarE tof) (VarE e))
            v

data EntityOptions = EntityOptions
    { eoTableName      :: String -> String -- ^ Type name to table name converter
    , eoColumnNames    :: String -> String -- ^ Record field to column name converter
    , eoDeriveClassess :: [Name]           -- ^ Typeclasses to derive for Id
    , eoIdType         :: Name             -- ^ Base type for Id
    }

instance Default EntityOptions where
    def = EntityOptions
        { eoTableName = id
        , eoColumnNames = id
        , eoDeriveClassess = [''Ord, ''Eq, ''Show]
        , eoIdType = ''Integer
        }

-- | Derives instance for 'Entity' using type name and field names.
deriveEntity :: EntityOptions -> Name -> Q [Dec]
deriveEntity opts tname = do
    TyConI (DataD _ _ _ [tcon] _) <- reify tname
    econt <- [t|Entity $(conT tname)|]
    ConT entityIdName <- [t|EntityId|]
    let tnames = nameBase tname
        idname = tnames ++ "Id"
        unidname = "get" ++ idname
        idtype = ConT (eoIdType opts)
        idcon = RecC (mkName idname)
                [(mkName unidname, NotStrict, idtype)]
        iddec = NewtypeInstD [] entityIdName [ConT tname]
                idcon (eoDeriveClassess opts)
        tblName = eoTableName opts tnames
        fldNames = map (eoColumnNames opts . nameBase) $ cFieldNames tcon
    VarE tableName  <- [e|tableName|]
    VarE fieldNames <- [e|fieldNames|]
    let tbldec = FunD tableName  [Clause [WildP] (NormalB $ LitE  $ stringL tblName) []]
        flddec = FunD fieldNames [Clause [WildP] (NormalB $ ListE $ map (LitE . stringL) fldNames) []]
        ret = InstanceD [] econt
              [ iddec, tbldec, flddec ]
        syndec = TySynD (mkName idname) [] (AppT (ConT entityIdName) (ConT tname))
    return [ret, syndec]



-- embed sql file as value
embedSql :: String               -- ^ File path
         -> Q Exp
embedSql path = do
    [e| (Query ( $(embedFile path) )) |]
{-# DEPRECATED embedSql "use 'sqlExpEmbed' instead" #-}

-- embed sql file by pattern. __sqlFile "dir/file"__ is just the same as
-- __embedSql "sql/dir/file.sql"__
sqlFile :: String                -- ^ sql file pattern
        -> Q Exp
sqlFile s = do
    embedSql $ "sql/" ++ s ++ ".sql"
{-# DEPRECATED sqlFile "use 'sqlExpFile' instead" #-}
