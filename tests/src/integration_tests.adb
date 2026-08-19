with Ada.Exceptions;
with Ada.Strings.Fixed;

with Frostlake;
with Test_Support;

package body Integration_Tests is

   use Frostlake;
   use Test_Support;

   function Contains (Haystack : String; Needle : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Haystack, Needle) > 0;
   end Contains;

   procedure Guarded
     (Label : String;
      What  : not null access procedure) is
   begin
      Note ("· " & Label);
      What.all;
   exception
      when E : others =>
         Record_Failure
           (Label & " raised "
            & Ada.Exceptions.Exception_Information (E));
   end Guarded;

   procedure Run (Dsn_Base : String) is

      procedure Create_Fixture is
         Admin : Connection := Connect (Dsn_Base);
      begin
         Admin.Execute ("CREATE OR REPLACE DATABASE ADA_DB");
         Admin.Execute ("CREATE OR REPLACE SCHEMA ADA_DB.S1");
         Admin.Close;
      end Create_Fixture;

   begin
      Note ("integration: against " & Dsn_Base);

      Guarded ("create fixture", Create_Fixture'Access);

      declare
         Conn : Connection := Connect (Dsn_Base & "/ADA_DB?schema=S1");

         procedure Test_Session_Defaults is
            R : constant Result := Conn.Execute
              ("SELECT CURRENT_DATABASE() AS D, CURRENT_SCHEMA() AS S");
         begin
            Check_Equal (As_String (Value (R, 1, "D")), "ADA_DB",
                         "current database from DSN");
            Check_Equal (As_String (Value (R, 1, "S")), "S1",
                         "current schema from DSN");
         end Test_Session_Defaults;

         procedure Test_Types_Round_Trip is
            Ntz : constant Timestamp_Value :=
              (Year => 2026, Month => 8, Day => 19,
               Hour => 10, Minute => 11, Second => 12,
               Nanosecond => 123_000_000,
               Has_Offset => False, Offset_Minutes => 0);
            Tz : constant Timestamp_Value :=
              (Year => 2026, Month => 8, Day => 19,
               Hour => 10, Minute => 11, Second => 12,
               Nanosecond => 123_000_000,
               Has_Offset => True, Offset_Minutes => 120);
            Blob : constant Cell :=
              To_Binary ([16#DE#, 16#AD#, 16#BE#, 16#EF#]);
         begin
            Conn.Execute
              ("CREATE OR REPLACE TABLE T_ALL ("
               & "ID NUMBER(10,0), NAME VARCHAR, PRICE NUMBER(10,2), "
               & "RATIO FLOAT, FLAG BOOLEAN, BIRTH DATE, "
               & "AT_NTZ TIMESTAMP_NTZ, AT_TZ TIMESTAMP_TZ, "
               & "BLOB BINARY, NOTE VARIANT)");
            declare
               R : constant Result := Conn.Execute
                 ("INSERT INTO T_ALL SELECT ?,?,?,?,?,?,?,?,?,?",
                  [To_Cell (Long_Long_Integer'(1)),
                   To_Cell ("Ada O'Hara \ Byron"),
                   To_Decimal ("12.34"),
                   To_Cell (Long_Float'(1.5)),
                   To_Cell (True),
                   To_Cell (Date_Value'(2024, 2, 29)),
                   To_Cell (Ntz),
                   To_Cell (Tz),
                   Blob,
                   To_Variant ("{""a"":1}")]);
            begin
               Check_Equal (Long_Long_Integer (R.Row_Count), 1,
                            "insert reported one row");
               Check (Column_Count (R) = 0,
                      "DML result carries no columns");
            end;
            declare
               R : constant Result := Conn.Execute
                 ("SELECT * FROM T_ALL");
            begin
               Check_Equal (Long_Long_Integer (R.Row_Count), 1,
                            "one row back");
               Check_Equal (As_Integer (Value (R, 1, "ID")), 1, "ID cell");
               Check_Equal (As_String (Value (R, 1, "NAME")),
                            "Ada O'Hara \ Byron", "NAME cell");
               Check (Value (R, 1, "PRICE").Kind = Decimal_Kind,
                      "PRICE keeps exact digits");
               Check_Equal (As_String (Value (R, 1, "PRICE")), "12.34",
                            "PRICE digits");
               Check (Value (R, 1, "RATIO").Kind = Float_Kind,
                      "RATIO is a float");
               Check (abs (As_Float (Value (R, 1, "RATIO")) - 1.5) < 1.0e-9,
                      "RATIO value");
               Check (As_Boolean (Value (R, 1, "FLAG")), "FLAG cell");
               Check (As_Date (Value (R, 1, "BIRTH"))
                        = Date_Value'(2024, 2, 29),
                      "BIRTH cell");
               Check (As_Timestamp (Value (R, 1, "AT_NTZ")) = Ntz,
                      "AT_NTZ cell, got "
                      & Image (Value (R, 1, "AT_NTZ")));
               declare
                  Got : constant Timestamp_Value :=
                    As_Timestamp (Value (R, 1, "AT_TZ"));
               begin
                  Check (Got.Has_Offset, "AT_TZ carries an offset");
                  Check (Got = Tz,
                         "AT_TZ cell, got "
                         & Image (Value (R, 1, "AT_TZ")));
               end;
               Check_Equal (Image (Value (R, 1, "BLOB")), "DEADBEEF",
                            "BLOB cell");
               Check (Value (R, 1, "NOTE").Kind = Variant_Kind,
                      "NOTE is variant");
               Check (Contains (As_String (Value (R, 1, "NOTE")), """a"""),
                      "NOTE json text, got "
                      & As_String (Value (R, 1, "NOTE")));
            end;
            Conn.Execute
              ("INSERT INTO T_ALL (ID) SELECT ?",
               [To_Cell (Long_Long_Integer'(2))]);
            declare
               Q : constant Result := Conn.Execute
                 ("SELECT NAME, FLAG FROM T_ALL WHERE ID = 2");
            begin
               Check (Is_Null (Value (Q, 1, "NAME")),
                      "NULL text cell");
               Check (Is_Null (Value (Q, 1, "FLAG")),
                      "NULL boolean cell");
            end;
         end Test_Types_Round_Trip;

         procedure Test_Exact_Numbers is
            R : constant Result := Conn.Execute
              ("SELECT 42 AS A, "
               & "12345678901234567890123456789012345678 AS B, "
               & "1.5 AS C, 100::FLOAT AS D");
         begin
            Check (Value (R, 1, "A").Kind = Integer_Kind, "42 is integer");
            Check_Equal (As_Integer (Value (R, 1, "A")), 42, "42 value");
            Check (Value (R, 1, "B").Kind = Decimal_Kind,
                   "38-digit number stays exact");
            Check_Equal
              (As_String (Value (R, 1, "B")),
               "12345678901234567890123456789012345678",
               "38-digit number digits");
            Check_Equal (As_String (Value (R, 1, "C")), "1.5",
                         "1.5 keeps its digits");
            Check (Value (R, 1, "D").Kind = Float_Kind, "FLOAT cell kind");
            Check (abs (As_Float (Value (R, 1, "D")) - 100.0) < 1.0e-9,
                   "FLOAT cell value");
         end Test_Exact_Numbers;

         procedure Test_Dml_Counts is
         begin
            Conn.Execute
              ("CREATE OR REPLACE TABLE T_DML (ID NUMBER, V VARCHAR)");
            declare
               R : constant Result := Conn.Execute
                 ("INSERT INTO T_DML VALUES (1,'a'), (2,'b'), (3,'c')");
            begin
               Check_Equal (Long_Long_Integer (R.Row_Count), 3,
                            "insert count");
            end;
            declare
               R : constant Result := Conn.Execute
                 ("UPDATE T_DML SET V = 'z' WHERE ID <= 2");
            begin
               Check_Equal (Long_Long_Integer (R.Row_Count), 2,
                            "update count");
            end;
            declare
               R : constant Result := Conn.Execute
                 ("DELETE FROM T_DML WHERE ID = 3");
            begin
               Check_Equal (Long_Long_Integer (R.Row_Count), 1,
                            "delete count");
            end;
            declare
               R : constant Result := Conn.Execute
                 ("SELECT COUNT(*) AS N FROM T_DML");
            begin
               Check_Equal (As_Integer (Value (R, 1, "N")), 2,
                            "count after DML");
            end;
         end Test_Dml_Counts;

         procedure Test_Errors is
         begin
            begin
               Conn.Execute ("SELECT * FROM NO_SUCH_TABLE_XYZ");
               Record_Failure ("bad query did not raise");
            exception
               when Query_Error =>
                  Check (Conn.Last_Error_Message'Length > 0,
                         "last error message kept");
            end;
            declare
               R : constant Result := Conn.Execute ("SELECT 1 AS OK");
            begin
               Check_Equal (As_Integer (Value (R, 1, "OK")), 1,
                            "connection usable after an error");
            end;
         end Test_Errors;

         procedure Test_Multi_Statement is
            All_Sets : constant Result_Vectors.Vector :=
              Conn.Execute_All ("SELECT 1 AS A; SELECT 2 AS B");
         begin
            Check_Equal
              (Long_Long_Integer (Natural (All_Sets.Length)), 2,
               "two result sets");
            Check_Equal
              (As_Integer (Value (All_Sets.Element (1), 1, "A")), 1,
               "first result set");
            Check_Equal
              (As_Integer (Value (All_Sets.Element (2), 1, "B")), 2,
               "second result set");
         end Test_Multi_Statement;

         procedure Test_Transactions is

            procedure Count_Is (Want : Long_Long_Integer; Label : String)
            is
               R : constant Result := Conn.Execute
                 ("SELECT COUNT(*) AS N FROM T_TX");
            begin
               Check_Equal (As_Integer (Value (R, 1, "N")), Want, Label);
            end Count_Is;

         begin
            Conn.Execute ("CREATE OR REPLACE TABLE T_TX (ID NUMBER)");

            Conn.Begin_Transaction;
            Conn.Execute ("INSERT INTO T_TX VALUES (1)");
            Conn.Rollback;
            Count_Is (0, "rollback undoes the insert");

            Conn.Begin_Transaction;
            Conn.Execute ("INSERT INTO T_TX VALUES (1)");
            Conn.Commit;
            Count_Is (1, "commit keeps the insert");
         end Test_Transactions;

         procedure Test_Transaction_Helper is

            procedure Insert_And_Fail (C : in out Connection) is
            begin
               C.Execute ("INSERT INTO T_TX VALUES (99)");
               raise Program_Error with "deliberate";
            end Insert_And_Fail;

            procedure Insert_Fine (C : in out Connection) is
            begin
               C.Execute ("INSERT INTO T_TX VALUES (7)");
            end Insert_Fine;

            procedure Failing_Tx is
              new Run_In_Transaction (Insert_And_Fail);
            procedure Working_Tx is
              new Run_In_Transaction (Insert_Fine);

            procedure Count_Is (Want : Long_Long_Integer; Label : String)
            is
               R : constant Result := Conn.Execute
                 ("SELECT COUNT(*) AS N FROM T_TX");
            begin
               Check_Equal (As_Integer (Value (R, 1, "N")), Want, Label);
            end Count_Is;

         begin
            begin
               Failing_Tx (Conn);
               Record_Failure ("failing transaction did not re-raise");
            exception
               when Program_Error =>
                  null;
            end;
            Count_Is (1, "helper rolled the failure back");

            Working_Tx (Conn);
            Count_Is (2, "helper committed the success");
         end Test_Transaction_Helper;

         procedure Test_Time_Cell is
            R : constant Result := Conn.Execute
              ("SELECT '12:34:56'::TIME AS T");
         begin
            Check (Value (R, 1, "T").Kind = Text_Kind,
                   "TIME arrives as text");
            Check_Equal (As_String (Value (R, 1, "T")), "12:34:56",
                         "TIME text");
         end Test_Time_Cell;

         procedure Test_Closed_Refusal is
            Spare : Connection := Connect (Dsn_Base);
         begin
            Spare.Close;
            Check (Spare.Is_Closed, "closed connection knows it");
            begin
               Spare.Execute ("SELECT 1");
               Record_Failure ("closed connection accepted a statement");
            exception
               when Usage_Error =>
                  null;
            end;
         end Test_Closed_Refusal;

      begin
         Guarded ("session defaults", Test_Session_Defaults'Access);
         Guarded ("types round trip", Test_Types_Round_Trip'Access);
         Guarded ("exact numbers", Test_Exact_Numbers'Access);
         Guarded ("dml counts", Test_Dml_Counts'Access);
         Guarded ("errors", Test_Errors'Access);
         Guarded ("multi statement", Test_Multi_Statement'Access);
         Guarded ("transactions", Test_Transactions'Access);
         Guarded ("transaction helper", Test_Transaction_Helper'Access);
         Guarded ("time cell", Test_Time_Cell'Access);
         Guarded ("closed refusal", Test_Closed_Refusal'Access);
         Conn.Close;
      end;
   exception
      when E : others =>
         Record_Failure
           ("integration suite died: "
            & Ada.Exceptions.Exception_Information (E));
   end Run;

end Integration_Tests;
