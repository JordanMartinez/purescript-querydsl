module QueryDsl (
  class SqlType,
  toConstant,
  Constant(..),
  Table,
  TypedColumn,
  Column,
  ColumnName,
  SelectQuery,
  UpdateQuery,
  InsertQuery,
  DeleteQuery,
  Expression,
  UntypedExpression,
  class ToExpression,
  BinaryOperator,
  UnaryOperator,
  ParameterizedSql(..),
  toExpression,
  alwaysTrue,
  makeTable,
  addColumn,
  column,
  from,
  join,
  select,
  update,
  insertInto,
  deleteFrom,
  class InsertExpressions,
  getInsertExpressions,
  class ApplyInsertExpressions,
  getInsertExpressions',
  class SelectExpressions,
  getSelectExpressions,
  class ApplySelectExpressions,
  getSelectExpressions',
  class UpdateExpressions,
  getUpdateExpressions,
  class ApplyUpdateExpressions,
  getUpdateExpressions',
  prefixOperator,
  postfixOperator,
  binaryOperator,
  columns,
  selectSql,
  insertSql,
  updateSql,
  deleteSql,
  expressionSql) where

import Prelude

import Control.Monad.Writer (Writer, runWriter, tell)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (class Foldable)
import Data.List (List(..), snoc, (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Data.String.CodeUnits (charAt, singleton)
import Data.Symbol (class IsSymbol, SProxy(..), reflectSymbol)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd, uncurry)
import Prim.Row (class Cons, class Lacks)
import Record as Record
import Type.Row (class RowToList, Cons, Nil, kind RowList, RLProxy(..), RProxy(..))

class SqlType t where
  toConstant :: t -> Constant

-- TODO: fromConstant!
-- todo: be more consistent wrt List vs Array

instance sqlTypeString :: SqlType String where
  toConstant = StringConstant

instance sqlTypeInt :: SqlType Int where
  toConstant = IntConstant

instance sqlTypeNumber :: SqlType Number where
  toConstant = NumberConstant

instance sqlTypeBoolean :: SqlType Boolean where
  toConstant true = IntConstant 1
  toConstant false = IntConstant 0

instance sqlTypeMaybe :: SqlType a => SqlType (Maybe a) where
  toConstant (Just x) = toConstant x
  toConstant Nothing = NullConstant

newtype TableName = TableName String

derive newtype instance eqTableName :: Eq TableName

newtype ColumnName = ColumnName String

derive newtype instance eqColumnName :: Eq ColumnName

data Table (cols :: #Type) = Table TableName (List UnTypedColumn) (TableName -> Record cols)

data UnTypedColumn = UnTypedColumn TableName ColumnName

newtype TypedColumn (name :: Symbol) typ = TypedColumn UnTypedColumn

data Column (name :: Symbol) typ = Column

-- | A query that selects data from a table
data SelectQuery (results :: #Type) a =
    FromSelectQuery TableName (TableName -> a)
  | JoinSelectQuery TableName (TableName -> a) (TableName -> Expression Boolean)
  | BindFromSelectQuery TableName (TableName -> SelectQuery results a)
  | BindJoinSelectQuery TableName (TableName -> SelectQuery results a) (TableName -> Expression Boolean)
  | SelectSelectQuery (List (Tuple ColumnName UntypedExpression)) (Expression Boolean)
  | InvalidSelectQuery

-- todo: add some quickcheck tests for these for the typeclass laws!

instance functorSelectQuery :: Functor (SelectQuery results) where
  map f (FromSelectQuery tName a) = FromSelectQuery tName (a >>> f)
  map f (JoinSelectQuery tName a expr) = JoinSelectQuery tName (a >>> f) expr
  map f (SelectSelectQuery cols filter) = SelectSelectQuery cols filter
  map f (BindFromSelectQuery tName tail) = BindFromSelectQuery tName (tail >>> map f)
  map f (BindJoinSelectQuery tName tail expr) = BindJoinSelectQuery tName (tail >>> map f) expr
  map f InvalidSelectQuery = InvalidSelectQuery

instance applySelectQuery :: Apply (SelectQuery results) where
  apply _ _ = InvalidSelectQuery

instance bindSelectQuery :: Bind (SelectQuery results) where
  bind (FromSelectQuery tName a) cmd =
    BindFromSelectQuery tName (\tName' -> cmd (a tName'))
  bind (JoinSelectQuery tName a expr) cmd =
    BindJoinSelectQuery tName (\tName' -> cmd (a tName')) expr
  bind (SelectSelectQuery cols filter) cmd =
    InvalidSelectQuery
  bind (BindFromSelectQuery tName f) cmd =
    InvalidSelectQuery
  bind (BindJoinSelectQuery tName f expr) cmd =
    InvalidSelectQuery
  bind InvalidSelectQuery cmd =
    InvalidSelectQuery

data UpdateQuery = UpdateQuery TableName (List (Tuple ColumnName UntypedExpression)) (Expression Boolean)

-- | A query that deletes data from a table
data DeleteQuery = DeleteQuery TableName (Expression Boolean)

data InsertQuery = InsertQuery TableName (List (Tuple ColumnName Constant))

data Constant = StringConstant String
              | IntConstant Int
              | NumberConstant Number
              | NullConstant

derive instance eqConstant :: Eq Constant

instance showConstant :: Show Constant where
  show (StringConstant s) = show s
  show (IntConstant i) = show i
  show (NumberConstant f) = show f
  show NullConstant = "null"

data UntypedExpression = PrefixOperatorExpr String UntypedExpression
                       | PostfixOperatorExpr String UntypedExpression
                       | BinaryOperatorExpr String UntypedExpression UntypedExpression
                       | ConstantExpr Constant
                       | ColumnExpr UnTypedColumn
                       | AlwaysTrueExpr

newtype Expression result = Expression UntypedExpression

class ToExpression a result | a -> result where
  toExpression :: a -> Expression result

instance toExpressionTypedColumn :: ToExpression (TypedColumn name typ) typ where
  toExpression (TypedColumn c) = Expression (ColumnExpr c)

else instance toExpressionExpression :: ToExpression (Expression result) result where
  toExpression e = e

else instance toExpressionConstant :: SqlType a => ToExpression a a where
  toExpression s = Expression (ConstantExpr $ toConstant s)

type UnaryOperator a input result =
  ToExpression a input =>
  a -> Expression result

type BinaryOperator a b input result =
  ToExpression a input =>
  ToExpression b input =>
  a -> b -> Expression result

data ParameterizedSql = ParameterizedSql String (Array Constant)

derive instance eqParameterizedSql :: Eq ParameterizedSql

instance showParameterizedSql :: Show ParameterizedSql where
  show (ParameterizedSql sql parameters) = show sql <> " with " <> show parameters

alwaysTrue :: Expression Boolean
alwaysTrue = Expression AlwaysTrueExpr

makeTable :: String -> Table ()
makeTable name = Table (TableName name) Nil (const {})

addColumn :: forall name typ oldCols newCols.
  SqlType typ =>
  IsSymbol name =>
  Lacks name oldCols =>
  Cons name (TypedColumn name typ) oldCols newCols =>
  Table oldCols ->
  Column name typ ->
  Table newCols
addColumn (Table tName cols makeRec) Column =
  Table tName (snoc cols $ UnTypedColumn tName cName) makeRec'
  where
    cName = ColumnName $ reflectSymbol cNameProxy

    cNameProxy = SProxy :: SProxy name

    makeRec' tName' =
      let col' = TypedColumn $ UnTypedColumn tName' cName in
      Record.insert cNameProxy col' (makeRec tName')

column :: forall name typ. Column name typ
column = Column

columns :: forall cols. Table cols -> Record cols
columns (Table name cols rec) = rec name

from :: forall cols results. Table cols -> SelectQuery results (Record cols)
from (Table tName _ cols) = FromSelectQuery tName cols

join :: forall cols results. Table cols -> (Record cols -> Expression Boolean) -> SelectQuery results (Record cols)
join (Table tName _ cols) expr =
  JoinSelectQuery tName cols (\tName' -> expr $ cols tName')

class SelectExpressions (exprs :: #Type) (result :: #Type) | exprs -> result where
  getSelectExpressions :: Record exprs -> List (Tuple ColumnName UntypedExpression)

instance selectExpressionsImpl
  :: ( RowToList exprsR exprsRL
     , RowToList resultsR resultsRL
     , ApplySelectExpressions exprsRL exprsR resultsRL ) => SelectExpressions exprsR resultsR
  where
    getSelectExpressions exprs = getSelectExpressions'
      (RLProxy :: RLProxy exprsRL) exprs (RLProxy :: RLProxy resultsRL)

class ApplySelectExpressions (exprsRL :: RowList) (exprsR :: #Type) (resultsRL :: RowList) where
  getSelectExpressions' :: RLProxy exprsRL -> Record exprsR -> RLProxy resultsRL -> List (Tuple ColumnName UntypedExpression)

instance applySelectExpressionsNil
  :: ApplySelectExpressions Nil exprsR Nil
  where
    getSelectExpressions' _ _ _ = Nil

instance applySelectExpressionsCons
  :: ( ApplySelectExpressions exprsRLTail exprsRTail resultsRLTail
     , IsSymbol name
     , ToExpression toExpr typ
     , Cons name toExpr exprsRTail exprsR
     , Lacks name exprsRTail ) =>
    ApplySelectExpressions (Cons name toExpr exprsRLTail) exprsR (Cons name typ resultsRLTail)
  where
    getSelectExpressions' _ exprs _ =
      Tuple cName uExpr : tail
      where
        nameProxy = SProxy :: SProxy name
        cName = ColumnName $ reflectSymbol nameProxy
        uExpr = untypeExpression $ toExpression $ Record.get nameProxy exprs
        tailExprs = Record.delete nameProxy exprs
        tail = getSelectExpressions'
          (RLProxy :: RLProxy exprsRLTail)
          (tailExprs :: Record exprsRTail)
          (RLProxy :: RLProxy resultsRLTail)

select :: forall exprs results. SelectExpressions exprs results => Record exprs -> Expression Boolean -> SelectQuery results Unit
select exprs filter = SelectSelectQuery (getSelectExpressions exprs) filter

class InsertExpressions (cols :: #Type) (exprs :: #Type) | cols -> exprs, exprs -> cols where
  getInsertExpressions :: Record exprs -> List (Tuple ColumnName Constant)

instance insertExpressionsImpl
 :: ( RowToList colsR colsRL
    , RowToList exprsR exprsRL
    , ApplyInsertExpressions colsRL exprsRL exprsR ) => InsertExpressions colsR exprsR
  where
    getInsertExpressions rec = getInsertExpressions'
     (RLProxy :: RLProxy colsRL)
     (RLProxy :: RLProxy exprsRL)
     (RProxy :: RProxy exprsR)
     rec

class ApplyInsertExpressions (colsRL :: RowList) (exprsRL :: RowList) (exprsR :: #Type)
  where
    getInsertExpressions' :: RLProxy colsRL -> RLProxy exprsRL -> RProxy exprsR -> Record exprsR -> List (Tuple ColumnName Constant)

instance applyInsertExpressionsNil
  :: ApplyInsertExpressions Nil Nil exprsR
    where
      getInsertExpressions' _ _ _ _ = Nil

instance applyInsertExpressionsCons
  :: ( ApplyInsertExpressions colsRLTail exprsRLTail exprsRTail
     , IsSymbol name
     , SqlType typ
     , Cons name typ exprsRTail exprsR
     , Lacks name exprsRTail ) =>
     ApplyInsertExpressions (Cons name (TypedColumn name typ) colsRLTail) (Cons name typ exprsRLTail) exprsR
    where
      getInsertExpressions' _ _ _ rec =
        Tuple cName cValue : tail
        where
          nameProxy = SProxy :: SProxy name
          cName = ColumnName $ reflectSymbol nameProxy
          cValue = toConstant $ Record.get nameProxy rec
          tailRec = Record.delete nameProxy rec
          tail = getInsertExpressions'
            (RLProxy :: RLProxy colsRLTail)
            (RLProxy :: RLProxy exprsRLTail)
            (RProxy :: RProxy exprsRTail)
            tailRec

insertInto :: forall cols exprs. InsertExpressions cols exprs => Table cols -> Record exprs -> InsertQuery
insertInto (Table tName _ _) exprs =
  InsertQuery tName $ List.reverse $ getInsertExpressions exprs

class UpdateExpressions (cols :: #Type) (exprs :: #Type) where
  getUpdateExpressions :: Record cols -> Record exprs -> List (Tuple ColumnName UntypedExpression)

instance updateExpressionsImpl
  :: ( RowToList colsR colsRL
     , RowToList exprsR exprsRL
     , ApplyUpdateExpressions colsRL exprsRL exprsR ) => UpdateExpressions colsR exprsR
  where
    getUpdateExpressions cols exprs = getUpdateExpressions'
      (RLProxy :: RLProxy colsRL) (RLProxy :: RLProxy exprsRL) exprs

class ApplyUpdateExpressions (colsRL :: RowList) (exprsRL :: RowList) (exprsR :: #Type) where
  getUpdateExpressions' :: RLProxy colsRL -> RLProxy exprsRL -> Record exprsR -> List (Tuple ColumnName UntypedExpression)

instance applyUpdateExpressionsNil
  :: ApplyUpdateExpressions colsRL Nil exprsR
  where
    getUpdateExpressions' _ _ _ = Nil

else instance applyUpdateExpressionsCons
  :: ( ApplyUpdateExpressions colsRLTail exprsRLTail exprsRTail
     , IsSymbol name
     , ToExpression toExpr typ
     , Cons name toExpr exprsRTail exprsR
     , Lacks name exprsRTail ) =>
    ApplyUpdateExpressions (Cons name (TypedColumn name typ) colsRLTail) (Cons name toExpr exprsRLTail) exprsR
  where
    getUpdateExpressions' _ _ exprs =
      Tuple cName uExpr : tail
      where
        nameProxy = SProxy :: SProxy name
        cName = ColumnName $ reflectSymbol nameProxy
        uExpr = untypeExpression $ toExpression $ Record.get nameProxy exprs
        tailExprs = Record.delete nameProxy exprs
        tail = getUpdateExpressions'
          (RLProxy :: RLProxy colsRLTail)
          (RLProxy :: RLProxy exprsRLTail)
          (tailExprs :: Record exprsRTail)

update :: forall cols exprs. UpdateExpressions cols exprs => Table cols -> Record exprs -> Expression Boolean -> UpdateQuery
update (Table tName _ cols) exprs filter =
  UpdateQuery tName (getUpdateExpressions (cols tName) exprs) filter

deleteFrom :: forall cols. Table cols -> Expression Boolean -> DeleteQuery
deleteFrom (Table tName  _ _) filter' = DeleteQuery tName filter'

untypeExpression :: forall a. Expression a -> UntypedExpression
untypeExpression (Expression ut) = ut

prefixOperator :: forall a input result. String -> UnaryOperator a input result
prefixOperator op a = Expression $ PrefixOperatorExpr op (untypeExpression $ toExpression a)

postfixOperator :: forall a input result. String -> UnaryOperator a input result
postfixOperator op a = Expression $ PostfixOperatorExpr op (untypeExpression $ toExpression a)

binaryOperator :: forall a b input result. String -> BinaryOperator a b input result
binaryOperator op a b = Expression $ BinaryOperatorExpr op (untypeExpression $ toExpression a) (untypeExpression $ toExpression b)

type SqlWriter = Writer (Array Constant) String

type AliasedTable = {
  name :: TableName,
  alias :: TableName
}

type JoinedTables = List (Tuple AliasedTable (Expression Boolean))

type FullSelectQuery = {
  rootTable :: AliasedTable,
  joinedTables :: Array (Tuple AliasedTable (Expression Boolean)),
  cols :: Array (Tuple ColumnName UntypedExpression),
  filter :: Expression Boolean
}

selectSql :: forall cols. SelectQuery cols Unit -> ParameterizedSql
selectSql query =
    case toFull query of
      Left err -> ParameterizedSql err [] -- todo!
      Right full -> uncurry ParameterizedSql $ runWriter $ toWriter full
  where
    toFull :: SelectQuery cols Unit -> Either String FullSelectQuery
    toFull (BindFromSelectQuery table tail) =
      let alias = makeAlias 0
          inner = tail alias
      in toFull' { name: table, alias } Nil inner
    toFull _ =
      Left "SQL query is missing initial from-clause"

    toFull' :: AliasedTable -> JoinedTables -> SelectQuery cols Unit -> Either String FullSelectQuery
    toFull' rootTable joinedTables (BindJoinSelectQuery table tail expr) =
      let alias = makeAlias $ List.length joinedTables + 1
          inner = tail alias
          joinTable = Tuple { name: table, alias } $ expr alias
      in toFull' rootTable (joinTable : joinedTables) inner
    toFull' rootTable joinedTables (SelectSelectQuery cols filter) =
      Right {
        rootTable,
        joinedTables: Array.fromFoldable $ List.reverse joinedTables,
        cols: Array.fromFoldable cols,
        filter
      }
    toFull' _ _ _ =
      Left "SQL query is missing join or select clause"

    toWriter :: FullSelectQuery -> SqlWriter
    toWriter { rootTable, joinedTables, cols, filter } = do
      sc <- selectClause
      fc <- fromClause
      wc <- whereClauseSql filter
      pure $ "select " <> sc <> " from " <> fc <> wc
      where
        selectClause = joinCsv <$> traverse selectCol cols

        selectCol (Tuple cName (ColumnExpr (UnTypedColumn tName' cName'))) =
          let start = tableColumnNameSql tName' cName'
          in pure $ if cName == cName'
                      then start
                      else start <> " as " <> columnNameSql cName
        selectCol (Tuple cName expr) = do
          sql <- untypedExpressionSql expr
          pure $ sql <> " as " <> columnNameSql cName

        fromClause = do
          jc <- joinWith " " <$> traverse joinClause joinedTables
          pure $ aliasSql rootTable <> jc

        joinClause (Tuple alias expr) = do
          e <- expressionSql' expr
          pure $ " join " <> aliasSql alias <> " on " <> e

        aliasSql { name, alias } =
          tableNameSql name <> " as " <> tableNameSql alias

makeAlias :: Int -> TableName
makeAlias i =
  case charAt i "abcdefghijklmnopqrstuvwxyz" of
    Just c -> TableName $ singleton c
    Nothing -> TableName $ "_" <> show i

deleteSql :: DeleteQuery -> ParameterizedSql
deleteSql (DeleteQuery tName filter) =
  let Tuple sql parameters = runWriter $ whereClauseSql filter in
  ParameterizedSql ("delete from " <> tableNameSql tName <> sql) parameters

insertSql :: InsertQuery -> ParameterizedSql
insertSql (InsertQuery tName columnValues) =
  uncurry ParameterizedSql $ runWriter writeSql
  where
    writeSql = do
      vs <- joinCsv <$> traverse (snd >>> constantSql) columnValues
      pure $ "insert into " <> tableNameSql tName <> " (" <> colsSql <> ") values (" <> vs <> ")"

    colsSql = joinCsv $ (fst >>> columnNameSql) <$> columnValues

updateSql :: UpdateQuery -> ParameterizedSql
updateSql (UpdateQuery tName columnValues filter) =
  uncurry ParameterizedSql $ runWriter writeSql
  where
    writeSql = do
      c <- colsSql
      wc <- whereClauseSql filter
      pure $ "update " <> tableNameSql tName <> " set " <> c <> wc

    colsSql = joinCsv <$> traverse colSql columnValues

    colSql (Tuple cName expr) = do
      e <- untypedExpressionSql expr
      pure $ columnNameSql cName <> " = " <> e

tableNameSql :: TableName -> String
tableNameSql (TableName name) = name -- TODO: quote if neccessary

columnNameSql :: ColumnName -> String
columnNameSql (ColumnName name) = name -- TODO: quote if neccessary

tableColumnNameSql :: TableName -> ColumnName -> String
tableColumnNameSql tName cName =
  tableNameSql tName <> "." <> columnNameSql cName

expressionSql :: forall result. Expression result -> ParameterizedSql
expressionSql e =
  uncurry ParameterizedSql $ runWriter (expressionSql' e)

expressionSql' :: forall result. Expression result -> SqlWriter
expressionSql' (Expression e) = untypedExpressionSql e

untypedExpressionSql :: UntypedExpression -> SqlWriter
untypedExpressionSql (PrefixOperatorExpr op a) = do
  sql <- untypedExpressionSql a
  pure $ "(" <> op <> " " <> sql <> ")"
untypedExpressionSql (PostfixOperatorExpr op a) = do
  sql <- untypedExpressionSql a
  pure $ "(" <> sql <> " " <> op <> ")"
untypedExpressionSql (BinaryOperatorExpr op a b) = do
  sqlA <- untypedExpressionSql a
  sqlB <- untypedExpressionSql b
  pure $ "(" <> sqlA <> " " <> op <> " " <> sqlB <> ")"
untypedExpressionSql (ConstantExpr c) =
  constantSql c
untypedExpressionSql (ColumnExpr (UnTypedColumn tName cName)) =
  pure $ tableColumnNameSql tName cName
untypedExpressionSql AlwaysTrueExpr =
  pure "(1 = 1)"

constantSql :: Constant -> SqlWriter
constantSql c = do
  tell [c]
  pure $ "?"

whereClauseSql :: Expression Boolean -> SqlWriter
whereClauseSql (Expression AlwaysTrueExpr) = pure ""
whereClauseSql expr = do
  e <- expressionSql' expr
  pure $ " where " <> e

joinCsv :: forall f. Foldable f => f String -> String
joinCsv = Array.fromFoldable >>> joinWith ", "
