{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}

module Write.TypeConverter
  ( TypeConverter
  , TypeEnv
  , TypeInfo(..)
  , cTypeToHsTypeString
  , cTypeToHsType
  , cTypeDependencyNames
  , cTypeInfo
  , buildTypeEnvFromSpec
  , buildTypeEnvFromSpecGraph
  , getTypeInfo
  , MemberInfo(..)
  , calculateMemberPacking
  , simpleCon
  , pattern TypeDef
  ) where

-- This file is gross TODO: clean

import Control.Arrow (second, (&&&))
import Control.Monad.State
import Data.List (foldl1')
import Data.Maybe (fromMaybe, catMaybes)
import Language.C.Types as C
import Language.Haskell.Exts.Pretty (prettyPrint)
import Language.Haskell.Exts.Syntax as HS hiding (ModuleName)
import Spec.Spec
import Spec.Graph
       (SpecGraph, getGraphCTypes, getGraphEnumTypes, getGraphStructTypes,
        getGraphUnionTypes, getGraphConstants)
import Spec.Constant
import Spec.Type
import Spec.TypeEnv
import Write.WriteMonad
import Write.Utils
import qualified Data.HashMap.Lazy as Map

type TypeConverter = CType -> String

pattern TypeDef t = TypeSpecifier (Specifiers [TYPEDEF] [] []) t

platformType :: String -> Write (Maybe HS.Type)
platformType s = 
  case s of
    "void"     -> Just <$> pure (TyCon (Special UnitCon))
    "char"     -> Just <$> conFromModule "Foreign.C.Types" "CChar"
    "float"    -> Just <$> conFromModule "Foreign.C.Types" "CFloat"
    "uint8_t"  -> Just <$> conFromModule "Data.Word" "Word8"
    "uint32_t" -> Just <$> conFromModule "Data.Word" "Word32"
    "uint64_t" -> Just <$> conFromModule "Data.Word" "Word64"
    "int32_t"  -> Just <$> conFromModule "Data.Int" "Int32"
    "size_t"   -> Just <$> conFromModule "Foreign.C.Types" "CSize"
    _          -> pure Nothing

cTypeToHsTypeString :: CType -> Write String
cTypeToHsTypeString cType = prettyPrint <$> cTypeToHsType cType

conFromModule :: String -> String -> Write HS.Type
conFromModule moduleName constructor = do
  tellRequiredName (ExternalName (ModuleName moduleName) constructor)
  pure (simpleCon constructor)

cTypeToHsType :: CType -> Write HS.Type
cTypeToHsType cType = hsType
  where 
    hsType = case cType of
               TypeSpecifier _ Void 
                 -> pure $ TyCon (Special UnitCon)
               TypeSpecifier _ (C.Char Nothing) 
                 -> conFromModule "Foreign.C.Types" "CChar"
               TypeSpecifier _ (C.Char (Just Signed)) 
                 -> conFromModule "Foreign.C.Types" "CChar"
               TypeSpecifier _ (C.Char (Just Unsigned)) 
                 -> conFromModule "Foreign.C.Types" "CUChar"
               TypeSpecifier _ Float 
                 -> conFromModule "Foreign.C.Types" "CFloat"
               TypeSpecifier _ (TypeName t) 
                 -> cIdToHsType t
               TypeDef (TypeName t) 
                 -> cIdToHsType t
               TypeDef (Struct t) 
                 -> cIdToHsType t
               Ptr _ (TypeSpecifier _ Void)
                 -> do ptrCon <- conFromModule "Foreign.Ptr" "Ptr" 
                       voidCon <- conFromModule "Data.Void" "Void"
                       pure $ ptrCon `TyApp` voidCon
               Ptr _ (Proto ret parameters) 
                 -> do funPtrCon <- conFromModule "Foreign.Ptr" "FunPtr" 
                       functionType <- makeFunctionType ret parameters
                       pure $ funPtrCon `TyApp` functionType
               Ptr _ t 
                 -> do ptrCon <- conFromModule "Foreign.Ptr" "Ptr" 
                       t <- cTypeToHsType t
                       pure $ ptrCon `TyApp` t
               Array s t 
                 -> do vecCon <- conFromModule "Data.Vector.Fixed.Storable" 
                                               "Vec"
                       sizeType <- sizeToPeano s
                       t <- cTypeToHsType t
                       pure $ vecCon `TyApp` sizeType `TyApp` t
               _ -> error ("Failed to convert C type:\n" ++ show cType)

cIdToHsType :: CIdentifier -> Write HS.Type
cIdToHsType i = do
  let s = unCIdentifier i
  platformTypeMay <- platformType s
  case platformTypeMay of
    Just pt -> pure pt
    Nothing -> pure $ simpleCon s

simpleCon :: String -> HS.Type
simpleCon = TyCon . UnQual . Ident

sizeToPeano :: ArrayType CIdentifier -> Write HS.Type
sizeToPeano s = case s of
                  VariablySized -> error "Variably sized arrays not handled"
                  Unsized -> error "Unsized arrays not handled"
                  SizedByInteger i -> do
                    tellExtension "DataKinds"
                    toPeanoType <- conFromModule "Data.Vector.Fixed.Cont" 
                                                 "ToPeano"
                    pure $ toPeanoType `TyApp` TyPromoted (PromotedInteger i)
                  SizedByIdentifier i -> do
                    tellExtension "DataKinds"
                    toPeanoType <- conFromModule "Data.Vector.Fixed.Cont" 
                                                 "ToPeano"
                    let typeName = Ident (unCIdentifier i)
                        typeNat = PromotedCon False (UnQual typeName)
                    pure $ toPeanoType `TyApp` TyPromoted typeNat

makeFunctionType :: CType -> [ParameterDeclaration CIdentifier] 
                 -> Write HS.Type
makeFunctionType ret [ParameterDeclaration _ (TypeSpecifier _ Void)] = makeFunctionType ret []
makeFunctionType ret parameters = 
  foldr TyFun <$>
        ((simpleCon "IO" `TyApp`) <$> cTypeToHsType ret) <*>
        (traverse (cTypeToHsType . parameterDeclarationType) parameters)

type TypeConvert = State TypeConvertState

data TypeConvertState = TypeConvertState{ nextVariable :: String
                                        }

initialTypeConvertState = TypeConvertState{ nextVariable = "a"
                                          }

getTypeVariable :: TypeConvert String
getTypeVariable = gets nextVariable <* modify incrementNextVariable

succLexicographic :: (Enum a, Ord a) => a -> a -> [a] -> [a]
succLexicographic lower _ [] = [lower]
succLexicographic lower upper (x:ys) = 
  if x >= upper 
    then lower : succLexicographic lower upper ys
    else succ x : ys

incrementNextVariable :: TypeConvertState -> TypeConvertState
incrementNextVariable (TypeConvertState n) = 
  TypeConvertState (succLexicographic 'a' 'z' n)

-- | cTypeNames returns the names of the C types this type depends on
cTypeDependencyNames :: CType -> [String]
cTypeDependencyNames cType = 
  case cType of 
    TypeSpecifier _ Void 
      -> ["void"]
    TypeSpecifier _ (C.Char Nothing) 
      -> ["char"]
    TypeSpecifier _ Float 
      -> ["float"]
    TypeSpecifier _ (TypeName t) 
      -> [unCIdentifier t]
    TypeDef (Struct t) 
      -> [unCIdentifier t]
    Ptr _ t
      -> cTypeDependencyNames t
    Array _ t 
      -> cTypeDependencyNames t
    Proto ret ps 
      -> cTypeDependencyNames ret ++ concatMap parameterTypeNames ps
    _ -> error ("Failed to get depended on names for C type:\n" ++ show cType)

parameterTypeNames :: ParameterDeclaration CIdentifier -> [String]
parameterTypeNames (ParameterDeclaration _ t) = cTypeDependencyNames t

getTypeInfo :: TypeEnv -> String -> TypeInfo
getTypeInfo env s = 
  case Map.lookup s (teTypeInfo env) of
    Nothing -> error ("Type missing from environment: " ++ s)
    Just ti -> ti
 
-- TODO: Remove
buildTypeEnvFromSpec :: Spec -> TypeEnv
buildTypeEnvFromSpec spec = 
  let constants = sConstants spec
      nameAndTypes = catMaybes . fmap getNameAndType $ sTypes spec
      getNameAndType typeDecl = 
        do name <- typeDeclTypeName typeDecl
           cType <- typeDeclCType typeDecl
           pure (name, cType)
      unions = catMaybes . fmap typeDeclToUnionType $ sTypes spec
      structs = catMaybes . fmap typeDeclToStructType $ sTypes spec
      enums = catMaybes . fmap typeDeclToEnumType $ sTypes spec
  in buildTypeEnv constants enums unions structs nameAndTypes

buildTypeEnvFromSpecGraph :: SpecGraph -> TypeEnv
buildTypeEnvFromSpecGraph graph = 
  let constants = getGraphConstants graph
      nameAndTypes = getGraphCTypes graph 
      unions = getGraphUnionTypes graph 
      structs = getGraphStructTypes graph 
      enums = getGraphEnumTypes graph
  in buildTypeEnv constants enums unions structs nameAndTypes

buildTypeEnv :: [Constant] -> [EnumType] -> [UnionType] -> [StructType] 
             -> [(String, CType)] 
             -> TypeEnv
buildTypeEnv constants enums unions structs typeDecls = env
  where -- Notice the recursive definition of env
        env = TypeEnv{..} 
        teIntegralConstants = Map.fromList . catMaybes . fmap getIntConstant $ constants
        teTypeInfo = Map.fromList ((second (cTypeInfo env) <$> typeDecls) ++
                                   structTypeInfos ++ unionTypeInfos ++ 
                                   enumTypeInfos)
        structTypeInfos = (stName &&& getStructTypeInfo env) <$> structs
        unionTypeInfos = (utName &&& getUnionTypeInfo env) <$> unions
        enumTypeInfos = zip (etName <$> enums) (repeat TypeInfo{ tiSize = 4 
                                                               , tiAlignment = 4
                                                               })

arrayTypeToSize :: Map.HashMap String Integer -> ArrayType CIdentifier -> Integer
arrayTypeToSize cs at = 
  case at of
    VariablySized -> error "Trying to get size of variably sized array"
    Unsized -> error "Trying to get size of unsized array"
    SizedByInteger i -> i
    SizedByIdentifier n -> 
      let string = unCIdentifier n
          value = Map.lookup string cs
      in case value of
           Nothing -> error ("Unknown identifier: " ++ string)
           Just v -> v

getIntConstant :: Constant -> Maybe (String, Integer)
getIntConstant c
  | IntegralValue i <- cValue c
  = Just (cName c, i)
  | otherwise
  = Nothing

cTypeInfo :: TypeEnv -> CType -> TypeInfo
cTypeInfo env t = 
  case t of
    TypeSpecifier _ Void 
      -> error "Void doesn't have a size or alignment"
    TypeSpecifier _ (C.Char Nothing) -> TypeInfo{ tiSize = 1
                                                , tiAlignment = 1
                                                }
    TypeSpecifier _ Float -> TypeInfo{ tiSize = 4
                                     , tiAlignment = 4
                                     }
    TypeSpecifier _ (TypeName tn) -> 
      case unCIdentifier tn of
        "uint8_t"  -> TypeInfo{ tiSize = 1
                              , tiAlignment = 1
                              }
        "uint32_t" -> TypeInfo{ tiSize = 4
                              , tiAlignment = 4
                              }
        "uint64_t" -> TypeInfo{ tiSize = 8
                              , tiAlignment = 8
                              }
        "int32_t"  -> TypeInfo{ tiSize = 4
                              , tiAlignment = 4
                              }
        "size_t"   -> TypeInfo{ tiSize = 8 -- TODO: 32 bit support
                              , tiAlignment = 8
                              }
        name ->  
          case Map.lookup name (teTypeInfo env) of
            Nothing -> error ("type name not found in environment: " ++ name)
            Just ti -> ti
    Ptr _ _ 
      -> TypeInfo{ tiSize = 8, tiAlignment = 8 } -- TODO: 32 bit support
    Array arrayType elementType 
      -> let length = arrayTypeToSize (teIntegralConstants env) arrayType
             typeInfo = cTypeInfo env elementType
             elementSize = tiSize typeInfo
             elementAlignment = tiAlignment typeInfo
         in TypeInfo{ tiSize = fromIntegral length * elementSize
                    , tiAlignment = elementAlignment
                    }
    _ -> error ("Failed to get typeinfo for C type:\n" ++ show t)

--------------------------------------------------------------------------------
-- Calculating member packing
--------------------------------------------------------------------------------

data MemberInfo = MemberInfo { miMember :: !StructMember
                             , miSize :: !Int
                             , miAlignment :: !Int
                             , miOffset :: !Int
                             }

getStructTypeInfo :: TypeEnv -> StructType -> TypeInfo
getStructTypeInfo env st = TypeInfo{..}
  where memberPacking = calculateMemberPacking env (stMembers st)
        lastMemberPacking = last memberPacking
        tiAlignment = foldl1' lcm -- You know, just in case!
                        (miAlignment <$> memberPacking)
        unalignedSize = miOffset lastMemberPacking +
                        miSize lastMemberPacking
        tiSize = alignTo tiAlignment unalignedSize

getUnionTypeInfo :: TypeEnv -> UnionType -> TypeInfo
getUnionTypeInfo env ut = TypeInfo{..}
  where memberPacking = calculateMemberPacking env (utMembers ut)
        tiAlignment = foldl1' lcm -- You know, just in case!
                        (miAlignment <$> memberPacking)
        unalignedSize = maximum (miSize <$> memberPacking)
        tiSize = alignTo tiAlignment unalignedSize

-- | Takes a list of members and calculates their packing 
calculateMemberPacking :: TypeEnv -> [StructMember] -> [MemberInfo]
calculateMemberPacking env = comb go 0
  where go offset m = let cType = smCType m
                          TypeInfo size alignment = cTypeInfo env cType
                          alignedOffset = alignTo alignment offset
                      in (alignedOffset + size, 
                          MemberInfo m size alignment alignedOffset)

comb :: (s -> a -> (s, b)) -> s -> [a] -> [b]
comb f initialState = go initialState []
  where go _ bs []     = reverse bs
        go s bs (a:as) = let (s', b) = f s a
                         in go s' (b:bs) as

alignTo :: Int -> Int -> Int
alignTo alignment offset = ((offset + alignment - 1) `div` alignment) *
                           alignment
