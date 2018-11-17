module Test.QueryDsl.SQLite3 (test) where

import Prelude

import Data.DateTime (DateTime)
import Data.DateTime.Instant (instant, toDateTime)
import Data.Maybe (fromJust)
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (bracket)
import Node.Buffer (Octet)
import Partial.Unsafe (unsafePartial)
import QueryDsl (Column, SelectQuery, Table, columns, deleteFrom, from, insertInto, makeTable, select, update)
import QueryDsl.Expressions ((:+), (:==), sum)
import QueryDsl.SQLite3 (runQuery, runSelectOneQuery)
import SQLite3 as SQLite3
import Test.QueryDsl.SQLite3.Expressions as Expressions
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Type.Data.Boolean (False, True)

createTableSql :: String
createTableSql = """
create table test (
  id integer not null primary key autoincrement,
  name text not null,
  count int not null
)
"""

testTable = makeTable "test" :: Table (
  id :: Column Int False,
  name :: Column String True,
  count :: Column Int True
)

selectCount :: SelectQuery (n :: Int)
selectCount = do
  t <- from testTable
  pure $ select {n: sum t.count}

test :: Spec Unit
test = do
  describe "Sqlite" do

    let withMemoryDb = bracket (SQLite3.newDB ":memory:") SQLite3.closeDB

    it "CRUD" do
      withMemoryDb \db -> do

        void $ SQLite3.queryDB db createTableSql []

        let t = columns testTable

        runQuery db $ insertInto testTable {name: "jim", count: 5}
        runQuery db $ insertInto testTable {name: "jane", count: 42}
        runQuery db $ insertInto testTable {name: "jean", count: 7}

        count <- runSelectOneQuery db selectCount
        count.n `shouldEqual` 54

        runQuery db $ update testTable {count: t.count :+ 1} (t.name :== "jim")

        count' <- runSelectOneQuery db selectCount
        count'.n `shouldEqual` 55

        runQuery db $ deleteFrom testTable (t.name :== "jean")

        count'' <- runSelectOneQuery db selectCount
        count''.n `shouldEqual` 48

    describe "Datatypes" do

      it "DateTime" do
        withMemoryDb \db -> do
          let testDateTime = toDateTime $ unsafePartial $ fromJust $ instant $ Milliseconds $ 123.0
              query = pure (select { dt: testDateTime }) :: SelectQuery (dt :: DateTime)
          result <- runSelectOneQuery db query
          result.dt `shouldEqual` testDateTime

      it "OctetArray" do
        withMemoryDb \db -> do
          let octets = [1, 2, 3]
              query = pure (select { a: octets }) :: SelectQuery (a :: Array Octet)
          result <- runSelectOneQuery db query
          result.a `shouldEqual` octets

  Expressions.test
