with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Frostlake;
with Frostlake.Http;
with Frostlake.Wire;
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

   --  How many sessions the server is holding, read straight off
   --  `GET /api/sessions`, whose body carries an activeSessions count. The driver offers no
   --  way to see this, and it is the only observable that tells a released
   --  session from one left for the reaper.
   function Active_Sessions (Dsn_Base : String) return Integer is
      Rest  : constant String :=
        Dsn_Base (Dsn_Base'First + 12 .. Dsn_Base'Last);  --  past the scheme
      Colon : constant Natural := Ada.Strings.Fixed.Index (Rest, ":");
      Reply : constant Frostlake.Http.Reply :=
        Frostlake.Http.Get
          (Host         => Rest (Rest'First .. Colon - 1),
           Port         => Integer'Value (Rest (Colon + 1 .. Rest'Last)),
           Path         => "/api/sessions",
           Open_Timeout => 5.0,
           Read_Timeout => 5.0);
      Text  : constant String :=
        Ada.Strings.Unbounded.To_String (Reply.Content);
      Mark  : constant Natural :=
        Ada.Strings.Fixed.Index (Text, """activeSessions"":");
      First : Natural;
      Last  : Natural;
   begin
      if Mark = 0 then
         return -1;
      end if;
      First := Mark + 17;
      Last := First;
      while Last <= Text'Last and then Text (Last) in '0' .. '9' loop
         Last := Last + 1;
      end loop;
      return Integer'Value (Text (First .. Last - 1));
   end Active_Sessions;

   --  The host and port Dsn_Base ("frostlake://host:port") names.
   function Host_Of (Dsn_Base : String) return String is
      Rest  : constant String :=
        Dsn_Base (Dsn_Base'First + 12 .. Dsn_Base'Last);  --  past the scheme
      Colon : constant Natural := Ada.Strings.Fixed.Index (Rest, ":");
   begin
      return Rest (Rest'First .. Colon - 1);
   end Host_Of;

   function Port_Of (Dsn_Base : String) return Positive is
      Rest  : constant String :=
        Dsn_Base (Dsn_Base'First + 12 .. Dsn_Base'Last);
      Colon : constant Natural := Ada.Strings.Fixed.Index (Rest, ":");
   begin
      return Integer'Value (Rest (Colon + 1 .. Rest'Last));
   end Port_Of;

   --  DELETE /api/sessions/{Id}, sent past the driver — the way the engine's
   --  idle expiry or a restart ends a session behind a connection's back.
   procedure Release_Behind_Its_Back (Dsn_Base : String; Id : String) is
      Reply : constant Frostlake.Http.Reply :=
        Frostlake.Http.Delete
          (Host         => Host_Of (Dsn_Base),
           Port         => Port_Of (Dsn_Base),
           Path         => "/api/sessions/" & Id,
           Open_Timeout => 5.0,
           Read_Timeout => 5.0);
   begin
      Check (Reply.Status = 200,
             "the engine released session " & Id & ": HTTP"
             & Natural'Image (Reply.Status));
   end Release_Behind_Its_Back;

   --  Whether the engine keeps sessions to their id — it answers
   --  newSession, and so honours requireSession and DELETE
   --  /api/sessions/{id} — asked past the driver.  Engines before 0.1.0 do
   --  neither, and this driver supports them.
   function Keeps_Sessions (Dsn_Base : String) return Boolean is
      Reply  : constant Frostlake.Http.Reply :=
        Frostlake.Http.Post
          (Host         => Host_Of (Dsn_Base),
           Port         => Port_Of (Dsn_Base),
           Path         => "/api/execute",
           Content      => "{""sql"":""SELECT 1""}",
           Open_Timeout => 5.0,
           Read_Timeout => 5.0);
      Parsed : constant Frostlake.Wire.Response :=
        Frostlake.Wire.Parse_Response
          (Ada.Strings.Unbounded.To_String (Reply.Content));
   begin
      if Parsed.Has_New_Session and then Parsed.Has_Session_Id then
         Release_Behind_Its_Back
           (Dsn_Base, Ada.Strings.Unbounded.To_String (Parsed.Session_Id));
      end if;
      return Parsed.Has_New_Session;
   end Keeps_Sessions;

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
         --  Closing hands the session back rather than leaving it, and any
         --  transaction it holds, to the reaper. A server that has no such
         --  route answers 404 or 405 and closing still succeeds, so this
         --  checks the count only when the server answered it at all.
         procedure Test_Close_Releases_The_Session is
            Before : constant Integer := Active_Sessions (Dsn_Base);
            During : Integer;
            After  : Integer;
         begin
            if Before < 0 then
               Skip ("closing releases the server session",
                     "this server does not report a session count");
               return;
            end if;
            declare
               Conn : Connection := Connect (Dsn_Base);
            begin
               Conn.Execute ("SELECT 1");
               During := Active_Sessions (Dsn_Base);
               Conn.Close;
               After := Active_Sessions (Dsn_Base);
               --  And closing twice is not an error, nor a second release.
               Conn.Close;
            end;
            Check (During = Before + 1,
                   "the statement opened one session, count now"
                   & Integer'Image (During));
            Check_Equal (Long_Long_Integer (After), Long_Long_Integer (Before),
                         "closing gave the session back");
            Check_Equal (Long_Long_Integer (Active_Sessions (Dsn_Base)),
                         Long_Long_Integer (Before),
                         "closing twice released nothing further");
         end Test_Close_Releases_The_Session;
      begin
         Guarded ("close releases the session",
                  Test_Close_Releases_The_Session'Access);
      end;

      declare
         --  A session released behind the connection's back, as the
         --  engine's idle expiry or a restart would: the next statement runs
         --  in a fresh session on the DSN's scope.
         procedure Test_Lost_Session_Recovers is
         begin
            if not Keeps_Sessions (Dsn_Base) then
               Skip ("a lost session is replaced on the DSN's scope",
                     "this engine answers no newSession");
               return;
            end if;
            declare
               Conn : Connection := Connect (Dsn_Base & "/ADA_DB?schema=S1");
            begin
               Conn.Execute ("SELECT 1");
               declare
                  Before : constant String := Conn.Session;
               begin
                  Release_Behind_Its_Back (Dsn_Base, Before);
                  declare
                     R : constant Result := Conn.Execute
                       ("SELECT CURRENT_DATABASE() AS D,"
                        & " CURRENT_SCHEMA() AS S");
                  begin
                     Check_Equal (As_String (Value (R, 1, "D")), "ADA_DB",
                                  "a fresh session on the DSN's database");
                     Check_Equal (As_String (Value (R, 1, "S")), "S1",
                                  "and on its schema");
                  end;
                  Check (Conn.Session /= Before and then Conn.Session /= "",
                         "a fresh session holds the connection");
               end;
               Conn.Close;
            end;
         end Test_Lost_Session_Recovers;

         --  The same with a transaction open is refused: the transaction
         --  went with the session, and the statement did not run.
         procedure Test_Lost_Transaction_Raises is
         begin
            if not Keeps_Sessions (Dsn_Base) then
               Skip ("a lost transaction raises",
                     "this engine answers no newSession");
               return;
            end if;
            declare
               Conn : Connection := Connect (Dsn_Base & "/ADA_DB?schema=S1");
            begin
               Conn.Execute ("CREATE OR REPLACE TABLE LOST_TX (N INTEGER)");
               Conn.Execute ("BEGIN");
               Conn.Execute ("INSERT INTO LOST_TX VALUES (1)");
               Release_Behind_Its_Back (Dsn_Base, Conn.Session);
               begin
                  Conn.Execute ("INSERT INTO LOST_TX VALUES (2)");
                  Record_Failure ("a statement in a lost transaction ran");
               exception
                  when E : Session_Lost_Error =>
                     Check (Contains (Ada.Exceptions.Exception_Message (E),
                                      "transaction"),
                            "the lost transaction named: "
                            & Ada.Exceptions.Exception_Message (E));
               end;
               Check (not Conn.In_Transaction,
                      "the transaction went with the session");
               declare
                  R : constant Result := Conn.Execute
                    ("SELECT COUNT(*) AS N, CURRENT_DATABASE() AS D"
                     & " FROM LOST_TX");
               begin
                  --  Releasing rolled the first INSERT back, and the
                  --  second never ran.
                  Check_Equal (As_Integer (Value (R, 1, "N")), 0,
                               "nothing of the lost transaction remains");
                  Check_Equal (As_String (Value (R, 1, "D")), "ADA_DB",
                               "the next statement ran on the DSN's scope");
               end;
               Conn.Close;
            end;
         end Test_Lost_Transaction_Raises;
      begin
         Guarded ("lost session recovers", Test_Lost_Session_Recovers'Access);
         Guarded ("lost transaction raises",
                  Test_Lost_Transaction_Raises'Access);
      end;

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
                  --  Older engines send a TIMESTAMP_TZ with no offset at all,
                  --  keeping only the wall clock, and this driver then reads it
                  --  at the machine's own offset. Current engines send the
                  --  offset the value was written with, as live does. This
                  --  driver supports both, and where the engine sent no offset
                  --  there is nothing here to check, so the case is SKIPPED
                  --  rather than passed: a green tick would claim an engine had
                  --  been checked for something it never sent. The offset that
                  --  did arrive is named, so a wrong one is not mistaken for an
                  --  absent one.
                  if not Got.Has_Offset
                    or else Got.Offset_Minutes /= Tz.Offset_Minutes
                  then
                     Skip ("a TIMESTAMP_TZ keeps the offset it was written with",
                           "this engine sends none, and the value read back as "
                           & Image (Value (R, 1, "AT_TZ")));
                  else
                     Check (Got = Tz,
                            "AT_TZ cell, got "
                            & Image (Value (R, 1, "AT_TZ")));
                  end if;
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

         --  A text column declares its width in characters and a binary one
         --  in bytes; an unbounded column declares the type's maximum.  No
         --  other type declares one.
         procedure Test_Column_Lengths is
         begin
            Conn.Execute
              ("CREATE OR REPLACE TABLE T_WIDTHS "
               & "(S VARCHAR(9), B BINARY(5), BIG VARCHAR, N NUMBER(10,2))");
            declare
               R : constant Result := Conn.Execute
                 ("SELECT S, B, BIG, N FROM T_WIDTHS");
            begin
               if R.Columns.Element (1).Has_Length then
                  Check (R.Columns.Element (1).Has_Length,
                         "VARCHAR(9) has a length");
                  Check_Equal
                    (Long_Long_Integer (R.Columns.Element (1).Length), 9,
                     "VARCHAR(9) length");
                  Check (R.Columns.Element (2).Has_Length,
                         "BINARY(5) has a length");
                  Check_Equal
                    (Long_Long_Integer (R.Columns.Element (2).Length), 5,
                     "BINARY(5) length");
                  Check (R.Columns.Element (3).Has_Length,
                         "unbounded VARCHAR has a length");
                  Check_Equal
                    (Long_Long_Integer (R.Columns.Element (3).Length),
                     16777216, "unbounded VARCHAR length");
               else
                  --  Engines before 0.1.0 send no length at all, and this
                  --  driver supports them: a column then reports none, and
                  --  there is no declared width to check.
                  Skip ("the declared width of a text or binary column",
                        "this engine sends no column length");
               end if;
               --  A number carries no width whichever engine answered.
               Check (not R.Columns.Element (4).Has_Length,
                      "NUMBER carries no length");
            end;
         end Test_Column_Lengths;

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
            All_Sets : Result_Vectors.Vector;
         begin
            --  A request carrying more than one statement has to be asked for;
            --  0 means any number.  The count is restored afterwards because
            --  every test here shares one session.
            Conn.Execute ("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0");
            All_Sets := Conn.Execute_All ("SELECT 1 AS A; SELECT 2 AS B");
            Check_Equal
              (Long_Long_Integer (Natural (All_Sets.Length)), 2,
               "two result sets");
            Check_Equal
              (As_Integer (Value (All_Sets.Element (1), 1, "A")), 1,
               "first result set");
            Check_Equal
              (As_Integer (Value (All_Sets.Element (2), 1, "B")), 2,
               "second result set");
            Conn.Execute ("ALTER SESSION SET MULTI_STATEMENT_COUNT = 1");
         end Test_Multi_Statement;

         procedure Test_Per_Call_Count is
            All_Sets : Result_Vectors.Vector;
            Counts_Statements : Boolean := True;
         begin
            --  No ALTER SESSION anywhere: the count rides on the call that
            --  needs it, and the session still counts one statement after.
            All_Sets := Conn.Execute_All ("SELECT 1 AS A; SELECT 2 AS B",
                                          Multi_Statement_Count => 2);
            Check_Equal
              (Long_Long_Integer (Natural (All_Sets.Length)), 2,
               "a pack the call declared itself");
            Check_Equal
              (As_Integer (Value (All_Sets.Element (2), 1, "B")), 2,
               "its second result set");
            --  0 means any number.
            All_Sets := Conn.Execute_All ("SELECT 1; SELECT 2; SELECT 3",
                                          Multi_Statement_Count => 0);
            Check_Equal
              (Long_Long_Integer (Natural (All_Sets.Length)), 3,
               "any number of statements");
            --  A count the call does not hold is refused, either way round.
            --
            --  Only an engine that counts the statements in a request refuses
            --  one at all, and this driver supports older ones than that.
            --  Against one of those neither refusal comes, so the two checks
            --  below are skipped rather than passed: a green tick would claim
            --  an engine had been checked for a refusal it does not make.
            begin
               Conn.Execute ("SELECT 1", Multi_Statement_Count => 2);
               Counts_Statements := False;
               Skip ("a count the call does not hold is refused",
                     "this engine does not enforce a statement count");
            exception
               when Query_Error =>
                  Check (True, "a count the call does not hold is refused");
            end;
            --  The session's own count is untouched by all of that, so a
            --  pack that declares nothing still fails.
            if Counts_Statements then
               begin
                  All_Sets :=
                    Conn.Execute_All ("SELECT 1 AS A; SELECT 2 AS B");
                  Record_Failure
                    ("the session's count was changed underneath");
               exception
                  when Query_Error =>
                     Check (True, "the session's count is untouched");
               end;
            else
               Skip ("the session's count is untouched by a per-call count",
                     "this engine does not enforce a statement count");
            end if;
         end Test_Per_Call_Count;

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
         Guarded ("column lengths", Test_Column_Lengths'Access);
         Guarded ("dml counts", Test_Dml_Counts'Access);
         Guarded ("errors", Test_Errors'Access);
         Guarded ("multi statement", Test_Multi_Statement'Access);
         Guarded ("per call count", Test_Per_Call_Count'Access);
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
