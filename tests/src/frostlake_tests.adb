--  The driver's test suite.  The unit half runs with no server and no
--  JVM — the wire pieces directly, the whole driver against a loopback
--  HTTP server.  The integration half boots a real DatabaseHttpServer
--  from FROSTLAKE_CLASSPATH and skips itself when that is unset.  Last,
--  the engine's testkit corpus is replayed when FL_CORPUS names it.

with Ada.Calendar;
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;
with GNAT.Sockets;

with Corpus_Tests;
with Frostlake.Http;
with Frostlake.Sql;
with Frostlake.Wire;
with Integration_Tests;
with Loopback;
with Test_Support;

procedure Frostlake_Tests is

   use Frostlake;
   use Test_Support;

   LF : constant Character := Character'Val (10);

   function Contains (Haystack : String; Needle : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Haystack, Needle) > 0;
   end Contains;

   function Img (Value : Integer) return String is
      Raw : constant String := Integer'Image (Value);
   begin
      if Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      end if;
      return Raw;
   end Img;

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

   ---------------------------------------------------------------
   --  SQL assembly
   ---------------------------------------------------------------

   procedure Test_Quote_Identifier is
   begin
      Check_Equal (Sql.Quote_Identifier ("People"), """People""",
                   "plain identifier quoted");
      Check_Equal (Sql.Quote_Identifier ("a""b"), """a""""b""",
                   "embedded quote doubled");
      begin
         declare
            Ignored : constant String := Sql.Quote_Identifier ("");
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("empty identifier accepted");
         end;
      exception
         when Usage_Error =>
            Check (True, "empty identifier refused");
      end;
   end Test_Quote_Identifier;

   procedure Test_Format_Literal is
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
      Tz_West : constant Timestamp_Value :=
        (Year => 2026, Month => 8, Day => 19,
         Hour => 10, Minute => 11, Second => 12,
         Nanosecond => 0,
         Has_Offset => True, Offset_Minutes => -450);
   begin
      Check_Equal (Sql.Format_Literal (Null_Cell), "NULL", "null literal");
      Check_Equal (Sql.Format_Literal (To_Cell (True)), "TRUE",
                   "true literal");
      Check_Equal (Sql.Format_Literal (To_Cell (False)), "FALSE",
                   "false literal");
      Check_Equal (Sql.Format_Literal (To_Cell (Long_Long_Integer'(-5))),
                   "-5", "negative integer literal");
      Check_Equal (Sql.Format_Literal (To_Decimal ("12.34")), "12.34",
                   "decimal literal");
      Check_Equal
        (Sql.Format_Literal (To_Cell ("Ada O'Hara \ Byron")),
         "'Ada O''Hara \\ Byron'", "text literal escaping");
      Check_Equal
        (Sql.Format_Literal (To_Cell (Date_Value'(2024, 2, 29))),
         "'2024-02-29'::DATE", "date literal");
      Check_Equal
        (Sql.Format_Literal (To_Cell (Ntz)),
         "'2026-08-19 10:11:12.123000000'::TIMESTAMP_NTZ",
         "naive timestamp literal");
      Check_Equal
        (Sql.Format_Literal (To_Cell (Tz)),
         "'2026-08-19T10:11:12.123000000+02:00'::TIMESTAMP_TZ",
         "zoned timestamp literal");
      Check_Equal
        (Sql.Format_Literal (To_Cell (Tz_West)),
         "'2026-08-19T10:11:12.000000000-07:30'::TIMESTAMP_TZ",
         "western offset literal");
      Check_Equal
        (Sql.Format_Literal (To_Binary ([16#DE#, 16#AD#, 16#BE#, 16#EF#])),
         "X'DEADBEEF'", "binary literal");
      Check_Equal
        (Sql.Format_Literal (To_Variant ("{""a"":1}")),
         "PARSE_JSON('{""a"":1}')", "variant literal");

      declare
         Rendered : constant String :=
           Sql.Format_Literal (To_Cell (Long_Float'(1.5)));
      begin
         Check (Sql.Is_Numeric_Literal (Rendered),
                "float renders as a numeric literal: " & Rendered);
         Check (abs (Long_Float'Value (Rendered) - 1.5) < 1.0e-12,
                "float literal round-trips: " & Rendered);
      end;

      declare
         Zero : Long_Float := 0.0;
         pragma Warnings (Off, Zero);
      begin
         declare
            Ignored : constant String :=
              Sql.Format_Literal (To_Cell (Zero / Zero));
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("NaN bind accepted");
         end;
      exception
         when Usage_Error =>
            Check (True, "NaN bind refused");
      end;

      begin
         declare
            Ignored : constant String := Sql.Format_Literal
              (Cell'(Kind => Decimal_Kind,
                     Exact => Ada.Strings.Unbounded.To_Unbounded_String
                                ("1; DROP TABLE X")));
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("mangled decimal accepted");
         end;
      exception
         when Usage_Error =>
            Check (True, "mangled decimal refused");
      end;
   end Test_Format_Literal;

   procedure Test_Substitute is
   begin
      Check_Equal
        (Sql.Substitute
           ("SELECT 'a?b', ""c?d"", ? -- e?f" & LF & ", ? /* g?h */",
            [To_Cell ("x"), To_Cell (Long_Long_Integer'(2))]),
         "SELECT 'a?b', ""c?d"", 'x' -- e?f" & LF & ", 2 /* g?h */",
         "skips literals, identifiers and comments");
      Check_Equal
        (Sql.Substitute ("SELECT ?",
                         [To_Cell ("Ada O'Hara \ Byron")]),
         "SELECT 'Ada O''Hara \\ Byron'",
         "encodes backslashes then quotes");
      Check_Equal
        (Sql.Substitute
           ("CREATE FUNCTION F() AS $$ return '?'; $$ // t?" & LF & "-- ?",
            No_Binds),
         "CREATE FUNCTION F() AS $$ return '?'; $$ // t?" & LF & "-- ?",
         "dollar-quoted bodies and both line comments left alone");
      Check_Equal
        (Sql.Substitute ("SELECT 'it''s ?', ?",
                         [To_Cell (Long_Long_Integer'(5))]),
         "SELECT 'it''s ?', 5",
         "doubled quote stays inside the literal");
      Check_Equal
        (Sql.Substitute ("SELECT 1 /* ?", No_Binds),
         "SELECT 1 /* ?",
         "unterminated block comment swallows the rest");
      begin
         declare
            Ignored : constant String :=
              Sql.Substitute ("SELECT ?, ?",
                              [To_Cell (Long_Long_Integer'(1))]);
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("missing bind accepted");
         end;
      exception
         when Usage_Error =>
            Check (True, "missing bind refused");
      end;
      Check_Equal
        (Sql.Substitute ("SELECT ?",
                         [To_Cell (Long_Long_Integer'(1)),
                          To_Cell (Long_Long_Integer'(2))]),
         "SELECT 1", "extra binds are not an error");
   end Test_Substitute;

   procedure Test_Selects_Session_State is
   begin
      Check (Sql.Selects_Session_State ("USE DATABASE X"), "plain USE");
      Check (Sql.Selects_Session_State ("   use schema y"),
             "indented lowercase USE");
      Check (Sql.Selects_Session_State ("SELECT 1; USE ROLE R"),
             "USE after a semicolon");
      Check (Sql.Selects_Session_State ("SELECT 1" & LF & "USE WAREHOUSE W"),
             "USE after a newline");
      Check (not Sql.Selects_Session_State ("SELECT 'USE THIS'"),
             "USE inside a line is not a USE statement");
      Check (not Sql.Selects_Session_State ("USELESS"),
             "USELESS is not USE");
      Check (not Sql.Selects_Session_State ("REFUSE DATABASE X"),
             "REFUSE is not USE");
   end Test_Selects_Session_State;

   --  What a fresh session would not have: a moved scope, a setting, a
   --  variable, or a temporary object — and what leaves the session alone.
   procedure Test_Touches_Session is
      procedure Touches (Statement : String) is
      begin
         Check (Sql.Touches_Session (Statement),
                Statement & " touches the session");
      end Touches;

      procedure Leaves (Statement : String) is
      begin
         Check (not Sql.Touches_Session (Statement),
                Statement & " leaves the session alone");
      end Leaves;
   begin
      Touches ("USE SCHEMA other");
      Touches ("set v = 1");
      Touches ("UNSET v");
      Touches ("ALTER SESSION SET TIMEZONE = 'UTC'");
      Touches ("CREATE DATABASE d");
      Touches ("CREATE OR REPLACE SCHEMA s");
      Touches ("DROP DATABASE IF EXISTS d");
      Touches ("CREATE TEMPORARY TABLE t (a INT)");
      Touches ("create temp table t (a int)");
      Touches ("CREATE OR REPLACE LOCAL TEMPORARY TABLE t (a INT)");
      Touches ("CREATE VOLATILE TABLE t (a INT)");
      Touches ("/* note */ -- more" & LF & " USE WAREHOUSE w");
      --  A USE riding behind another statement still counts.
      Touches ("SELECT 1; USE SCHEMA other");

      Leaves ("SELECT 1");
      Leaves ("CREATE TABLE t (a INT)");
      Leaves ("CREATE TRANSIENT TABLE t (a INT)");
      Leaves ("CREATE TABLE temporary (a INT)");
      Leaves ("DROP TABLE temp");
      Leaves ("ALTER TABLE t ADD COLUMN c INT");
      Leaves ("INSERT INTO t VALUES (1)");
      --  The same words inside a literal, a comment or a $$ body do not.
      Leaves ("SELECT 'x; USE SCHEMA other'");
      Leaves ("SELECT 1 -- ; SET v = 1");
      Leaves ("SELECT $$ ; USE SCHEMA other $$");
   end Test_Touches_Session;

   procedure Test_Transaction_Effect is
      use type Sql.Transaction_Change;

      procedure Expect (Statement : String; Want : Sql.Transaction_Change)
      is
      begin
         Check (Sql.Transaction_Effect (Statement) = Want,
                Statement & " is "
                & Sql.Transaction_Change'Image (Want));
      end Expect;
   begin
      Expect ("BEGIN", Sql.Opens);
      Expect ("begin transaction", Sql.Opens);
      Expect ("BEGIN WORK", Sql.Opens);
      Expect ("BEGIN NAME t1", Sql.Opens);
      Expect ("START TRANSACTION", Sql.Opens);
      Expect ("COMMIT", Sql.Closes);
      Expect ("rollback work", Sql.Closes);
      --  BEGIN followed by a statement opens a scripting block.
      Expect ("BEGIN" & LF & "  SELECT 1", Sql.No_Change);
      Expect ("START TASK t", Sql.No_Change);
      Expect ("SELECT 1", Sql.No_Change);
      Expect ("", Sql.No_Change);
      --  A request is what its last such statement leaves it as.
      Expect ("BEGIN; INSERT INTO t VALUES (1); COMMIT", Sql.Closes);
      Expect ("BEGIN; INSERT INTO t VALUES (1)", Sql.Opens);
   end Test_Transaction_Effect;

   ---------------------------------------------------------------
   --  Wire protocol
   ---------------------------------------------------------------

   procedure Test_Escape_Json is
   begin
      Check_Equal
        (Wire.Escape_Json ("a""b\c" & LF & Character'Val (9)
                           & Character'Val (1)),
         "a\""b\\c\n\t\u0001", "json escaping");
   end Test_Escape_Json;

   procedure Test_Build_Request is
   begin
      Check_Equal
        (Wire.Build_Execute_Request ("SELECT 1", "", True),
         "{""sql"":""SELECT 1"",""autoCommit"":true}",
         "request without a session");
      Check_Equal
        (Wire.Build_Execute_Request ("SELECT 1", "abc", False),
         "{""sql"":""SELECT 1"",""autoCommit"":false,"
         & """sessionId"":""abc""}",
         "request with a session");
      --  A request that declares no count carries no field at all, so the
      --  session's MULTI_STATEMENT_COUNT keeps deciding.
      Check_Equal
        (Wire.Build_Execute_Request
           ("SELECT 1", "", True, No_Multi_Statement_Count),
         "{""sql"":""SELECT 1"",""autoCommit"":true}",
         "request without a count");
      Check_Equal
        (Wire.Build_Execute_Request ("SELECT 1; SELECT 2", "abc", True, 2),
         "{""sql"":""SELECT 1; SELECT 2"",""autoCommit"":true,"
         & """sessionId"":""abc"",""multiStatementCount"":2}",
         "request with a count");
      --  0 is a count like any other — any number — not an absent one.
      Check_Equal
        (Wire.Build_Execute_Request ("SELECT 1; SELECT 2", "", True, 0),
         "{""sql"":""SELECT 1; SELECT 2"",""autoCommit"":true,"
         & """multiStatementCount"":0}",
         "request asking for any number");
   end Test_Build_Request;

   procedure Test_Parse_Success_Response is
      Parsed : constant Wire.Response := Wire.Parse_Response
        ("{""success"":true,""sessionId"":""s-1"",""resultSets"":[{"
         & """columns"":[{""name"":""ID"",""dataType"":""NUMBER"","
         & """precision"":38,""scale"":0,""nullable"":false},"
         & "{""name"":""N"",""dataType"":""VARCHAR"",""nullable"":true}],"
         & """rows"":[[1,""x""],[null,""\u00e9\ud83d\ude00""]],"
         & """rowCount"":2}],""executionTimeMs"":7}");
      Emoji : constant String :=
        Character'Val (195) & Character'Val (169)
        & Character'Val (240) & Character'Val (159)
        & Character'Val (152) & Character'Val (128);
   begin
      Check (Parsed.Success, "success flag");
      Check (Parsed.Has_Session_Id
             and then Ada.Strings.Unbounded.To_String (Parsed.Session_Id)
                        = "s-1",
             "session id");
      Check_Equal
        (Long_Long_Integer (Natural (Parsed.Result_Sets.Length)), 1,
         "one result set");
      declare
         Set : constant Result := Parsed.Result_Sets.Element (1);
      begin
         Check_Equal (Long_Long_Integer (Column_Count (Set)), 2,
                      "two columns");
         Check_Equal (Column_Name (Set, 1), "ID", "first column name");
         Check (Set.Columns.Element (1).Can_Be_Null = Not_Nullable,
                "nullable false maps");
         Check (Set.Columns.Element (2).Can_Be_Null = Nullable,
                "nullable true maps");
         Check_Equal (As_Integer (Value (Set, 1, "ID")), 1,
                      "integer cell");
         Check_Equal (As_String (Value (Set, 1, "N")), "x", "text cell");
         Check (Is_Null (Value (Set, 2, "ID")), "null cell");
         Check_Equal (As_String (Value (Set, 2, "N")), Emoji,
                      "unicode escapes incl. surrogate pair");
         Check_Equal (Long_Long_Integer (Set.Row_Count), 2, "row count");
      end;
   end Test_Parse_Success_Response;

   --  Only text and binary columns declare a width; anything else, and any
   --  server that predates the field, leaves Has_Length False rather than
   --  reporting a width of zero.
   procedure Test_Parse_Column_Length is
      Parsed : constant Wire.Response := Wire.Parse_Response
        ("{""success"":true,""resultSets"":[{"
         & """columns"":[{""name"":""S"",""dataType"":""VARCHAR"","
         & """precision"":0,""scale"":0,""length"":9},"
         & "{""name"":""B"",""dataType"":""BINARY"","
         & """precision"":0,""scale"":0,""length"":5},"
         & "{""name"":""BIG"",""dataType"":""VARCHAR"","
         & """precision"":0,""scale"":0,""length"":16777216},"
         & "{""name"":""N"",""dataType"":""NUMBER"","
         & """precision"":10,""scale"":2}],"
         & """rows"":[],""rowCount"":0}],""executionTimeMs"":1}");
      Set : constant Result := Parsed.Result_Sets.Element (1);
   begin
      Check (Set.Columns.Element (1).Has_Length, "VARCHAR(9) has a length");
      Check_Equal (Long_Long_Integer (Set.Columns.Element (1).Length), 9,
                   "VARCHAR(9) length");
      Check (Set.Columns.Element (2).Has_Length, "BINARY(5) has a length");
      Check_Equal (Long_Long_Integer (Set.Columns.Element (2).Length), 5,
                   "BINARY(5) length");
      Check (Set.Columns.Element (3).Has_Length,
             "unbounded VARCHAR has a length");
      Check_Equal (Long_Long_Integer (Set.Columns.Element (3).Length),
                   16777216, "unbounded VARCHAR length");
      Check (not Set.Columns.Element (4).Has_Length,
             "NUMBER carries no length");
      Check_Equal (Long_Long_Integer (Set.Columns.Element (4).Length), 0,
                   "an absent length leaves the default");
   end Test_Parse_Column_Length;

   procedure Test_Parse_Shuffled_Response is
      Parsed : constant Wire.Response := Wire.Parse_Response
        ("{""future"":{""x"":[1,{""y"":""z""}]},""resultSets"":[{"
         & """rows"":[[""2026-01-02""]],""rowCount"":1,"
         & """columns"":[{""name"":""D"",""dataType"":""DATE""}]}],"
         & """success"":true,""weird"":[true,null,-1.5e3]}");
      Set : constant Result := Parsed.Result_Sets.Element (1);
   begin
      Check (Parsed.Success, "success despite unknown fields");
      Check (Value (Set, 1, "D").Kind = Date_Kind,
             "rows before columns still typed");
      Check (As_Date (Value (Set, 1, "D")) = Date_Value'(2026, 1, 2),
             "date cell value");
   end Test_Parse_Shuffled_Response;

   procedure Test_Parse_New_Session is
      Fresh : constant Wire.Response := Wire.Parse_Response
        ("{""success"":true,""sessionId"":""s-1"",""newSession"":true,"
         & """resultSets"":[]}");
      Kept : constant Wire.Response := Wire.Parse_Response
        ("{""success"":true,""sessionId"":""s-1"",""newSession"":false,"
         & """resultSets"":[]}");
      Silent : constant Wire.Response := Wire.Parse_Response
        ("{""success"":true,""sessionId"":""s-1"",""resultSets"":[]}");
   begin
      Check (Fresh.Has_New_Session and then Fresh.New_Session,
             "the server said it started a fresh session");
      Check (Kept.Has_New_Session and then not Kept.New_Session,
             "the server said it reused the session");
      --  An engine from before the field says nothing, which has to stay
      --  distinguishable from one that said False: only the second is a
      --  promise that the session was kept.
      Check (not Silent.Has_New_Session,
             "an absent field is not a False one");
      Check (not Silent.New_Session, "and reads as False by default");
   end Test_Parse_New_Session;

   procedure Test_Parse_Error_Response is
      Parsed : constant Wire.Response := Wire.Parse_Response
        ("{""success"":false,""sessionId"":""s-2"","
         & """errorMessage"":""Compilation error:\nline 1"","
         & """resultSets"":[]}");
   begin
      Check (not Parsed.Success, "failure flag");
      Check (Parsed.Has_Error_Message, "error message present");
      Check (Contains (Ada.Strings.Unbounded.To_String
                         (Parsed.Error_Message), "line 1"),
             "multi-line error survives");
   end Test_Parse_Error_Response;

   procedure Test_Parse_Garbage is
   begin
      begin
         declare
            Ignored : constant Wire.Response :=
              Wire.Parse_Response ("it is tuesday");
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("garbage body parsed");
         end;
      exception
         when Wire.Parse_Error =>
            Check (True, "garbage body refused");
      end;
      begin
         declare
            Ignored : constant Wire.Response :=
              Wire.Parse_Response ("{""success"":true");
            pragma Unreferenced (Ignored);
         begin
            Record_Failure ("truncated body parsed");
         end;
      exception
         when Wire.Parse_Error =>
            Check (True, "truncated body refused");
      end;
   end Test_Parse_Garbage;

   procedure Test_Retype is
      function Text_Cell (Text : String) return Cell is
        ((Kind => Text_Kind,
          Text => Ada.Strings.Unbounded.To_Unbounded_String (Text)));
      function Decimal_Cell (Text : String) return Cell is
        ((Kind => Decimal_Kind,
          Exact => Ada.Strings.Unbounded.To_Unbounded_String (Text)));
   begin
      Check (Wire.Retype (Decimal_Cell ("5.00"), "NUMBER", 0).Kind
               = Integer_Kind,
             "integral decimal at scale 0 becomes integer");
      Check (Wire.Retype (Decimal_Cell ("5.50"), "NUMBER", 0).Kind
               = Decimal_Kind,
             "fractional value never truncated");
      Check (Wire.Retype (Decimal_Cell ("5.50"), "NUMBER", 2).Kind
               = Decimal_Kind,
             "scaled column keeps digits");
      Check (Wire.Retype
               (Decimal_Cell ("12345678901234567890123456789012345678"),
                "NUMBER", 0).Kind = Decimal_Kind,
             "38 digits stay exact");
      Check (Wire.Retype (Decimal_Cell ("1.5"), "FLOAT", 0).Kind
               = Float_Kind,
             "float column converts decimals");
      Check (abs (Wire.Retype ((Kind => Integer_Kind, Int => 100),
                               "DOUBLE", 0).Real - 100.0) < 1.0e-9,
             "float column converts integers");
      Check (Wire.Retype (Text_Cell ("2026-08-07"), "DATE", 0).Kind
               = Date_Kind,
             "date text parsed");
      Check (Wire.Retype (Text_Cell ("not a date"), "DATE", 0).Kind
               = Text_Kind,
             "unreadable date left as text");
      declare
         Got : constant Cell := Wire.Retype
           (Text_Cell ("2026-08-07 12:34:56.789"), "TIMESTAMP_NTZ", 0);
      begin
         Check (Got.Kind = Timestamp_Kind
                and then not Got.Stamp.Has_Offset
                and then Got.Stamp.Nanosecond = 789_000_000,
                "naive timestamp parsed");
      end;
      declare
         Got : constant Cell := Wire.Retype
           (Text_Cell ("2026-08-07 12:34:56.789 -0700"),
            "TIMESTAMP_TZ", 0);
      begin
         Check (Got.Kind = Timestamp_Kind
                and then Got.Stamp.Has_Offset
                and then Got.Stamp.Offset_Minutes = -420,
                "zoned timestamp parsed");
      end;
      Check (Image (Wire.Retype (Text_Cell ("DEADBEEF"), "BINARY", 0))
               = "DEADBEEF",
             "hex decoded and re-imaged");
      Check (Wire.Retype (Text_Cell ("XYZ1"), "BINARY", 0).Kind
               = Text_Kind,
             "non-hex left alone");
      Check (Wire.Retype (Text_Cell ("ABC"), "BINARY", 0).Kind
               = Text_Kind,
             "odd-length hex left alone");
      Check (Wire.Retype (Text_Cell ("{""a"":1}"), "VARIANT", 0).Kind
               = Variant_Kind,
             "variant text marked");
      Check (Wire.Retype (Text_Cell ("12:34:56"), "TIME", 0).Kind
               = Text_Kind,
             "TIME stays text");
   end Test_Retype;

   procedure Test_Wire_Temporals is
      TS : Timestamp_Value;
      D  : Date_Value;
      Ok : Boolean;
   begin
      Wire.Parse_Wire_Timestamp
        ("2026-08-19T10:00:00.123456+02:00", TS, Ok);
      Check (Ok and then TS.Nanosecond = 123_456_000
             and then TS.Offset_Minutes = 120 and then TS.Has_Offset,
             "bind-shaped timestamp accepted");
      Wire.Parse_Wire_Timestamp ("2026-08-19 10:00:00", TS, Ok);
      Check (Ok and then TS.Nanosecond = 0 and then not TS.Has_Offset,
             "fraction-less timestamp accepted");
      Wire.Parse_Wire_Timestamp ("2026-08-19 10:00:00Z", TS, Ok);
      Check (Ok and then TS.Has_Offset and then TS.Offset_Minutes = 0,
             "Z offset accepted");
      Wire.Parse_Wire_Timestamp ("2026-08-19 10:00:00xyz", TS, Ok);
      Check (not Ok, "trailing junk refused");
      Wire.Parse_Wire_Timestamp ("2026-08-19 10:00", TS, Ok);
      Check (not Ok, "short timestamp refused");
      Wire.Parse_Wire_Date ("2026-08-07", D, Ok);
      Check (Ok and then D = Date_Value'(2026, 8, 7), "date accepted");
      Wire.Parse_Wire_Date ("2026-8-7", D, Ok);
      Check (not Ok, "loose date refused");
      Wire.Parse_Wire_Date ("2026-13-01", D, Ok);
      Check (not Ok, "month 13 refused");
   end Test_Wire_Temporals;

   procedure Test_Numeric_Text is
      V  : Long_Long_Integer;
      Ok : Boolean;
   begin
      Wire.To_Integer_If_Integral ("5", V, Ok);
      Check (Ok and then V = 5, "plain integer");
      Wire.To_Integer_If_Integral ("-5", V, Ok);
      Check (Ok and then V = -5, "negative integer");
      Wire.To_Integer_If_Integral ("5.000", V, Ok);
      Check (Ok and then V = 5, "zero fraction is integral");
      Wire.To_Integer_If_Integral ("5.01", V, Ok);
      Check (not Ok, "real fraction is not");
      Wire.To_Integer_If_Integral ("1e2", V, Ok);
      Check (not Ok, "exponent is not");
      Wire.To_Integer_If_Integral
        ("99999999999999999999999999999999", V, Ok);
      Check (not Ok, "overflow refused");
      Check (abs (Wire.To_Long_Float ("1e2") - 100.0) < 1.0e-9,
             "bare exponent normalized");
      Check (abs (Wire.To_Long_Float ("-4.5") + 4.5) < 1.0e-12,
             "plain real");
   end Test_Numeric_Text;

   procedure Test_Dml_Shapes is
      Cols : Column_Vectors.Vector;
      Row  : Cell_Vectors.Vector;

      function Named (Name : String) return Column_Info is
        ((Name      => Ada.Strings.Unbounded.To_Unbounded_String (Name),
          Data_Type =>
            Ada.Strings.Unbounded.To_Unbounded_String ("NUMBER"),
          Precision => 38, Scale => 0, Can_Be_Null => Unknown,
          others    => <>));
   begin
      Check (not Wire.Is_Dml_Status (Cols), "no columns is not a status");
      Cols.Append (Named ("number of rows inserted"));
      Row.Append (Cell'(Kind => Integer_Kind, Int => 2));
      Check (Wire.Is_Dml_Status (Cols), "insert counter is a status");
      Check_Equal (Long_Long_Integer (Wire.Dml_Row_Count (Cols, Row)), 2,
                   "insert count");
      Cols.Append (Named ("number of rows updated"));
      Row.Append (Cell'(Kind => Integer_Kind, Int => 3));
      Cols.Append (Named ("number of multi-joined rows updated"));
      Row.Append (Cell'(Kind => Integer_Kind, Int => 1));
      Check (Wire.Is_Dml_Status (Cols), "merge counters are a status");
      Check_Equal (Long_Long_Integer (Wire.Dml_Row_Count (Cols, Row)), 5,
                   "diagnostic sub-count left out");
      Cols.Append (Named ("ID"));
      Check (not Wire.Is_Dml_Status (Cols),
             "a data column breaks the shape");
   end Test_Dml_Shapes;

   ---------------------------------------------------------------
   --  DSN handling (all failures happen before any network)
   ---------------------------------------------------------------

   procedure Expect_Usage
     (Dsn      : String;
      Fragment : String;
      Label    : String) is
   begin
      declare
         C : Connection := Connect (Dsn);
      begin
         C.Close;
         Record_Failure (Label & ": no exception");
      end;
   exception
      when E : Usage_Error =>
         Check
           (Contains (Ada.Exceptions.Exception_Message (E), Fragment),
            Label & " message: "
            & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Record_Failure
           (Label & " wrong exception: "
            & Ada.Exceptions.Exception_Information (E));
   end Expect_Usage;

   procedure Test_Dsn_Errors is
   begin
      Expect_Usage ("nonsense", "must start with", "scheme-less DSN");
      Expect_Usage ("gopher://h", "must start with", "unknown scheme");
      Expect_Usage ("https://h", "https", "https refused");
      Expect_Usage ("frostlake://u:p@h", "credentials",
                    "credentials refused");
      Expect_Usage ("frostlake://", "missing host", "empty authority");
      Expect_Usage ("frostlake://h/db/extra", "one database",
                    "two-segment path");
      Expect_Usage ("frostlake://h:70000", "between 1 and 65535",
                    "port too big");
      Expect_Usage ("frostlake://h:0", "between 1 and 65535", "port zero");
      Expect_Usage ("frostlake://h:12x", "between 1 and 65535",
                    "non-numeric port");
      Expect_Usage ("frostlake://h?wibble=1&aaa=2", "aaa, wibble",
                    "unknown parameters listed sorted");
      Expect_Usage ("frostlake://h?verify_ssl=false", "https DSNs only",
                    "tls params refused on http");
      Expect_Usage ("frostlake://h?open_timeout=abc",
                    "number of seconds", "non-numeric timeout");
      Expect_Usage ("frostlake://h?read_timeout=0", "must be positive",
                    "zero timeout");
      Expect_Usage ("frostlake://h?session_idle_limit=-5",
                    "cannot be negative", "negative idle limit");
   end Test_Dsn_Errors;

   ---------------------------------------------------------------
   --  The whole driver against the loopback server
   ---------------------------------------------------------------

   Plain_Ok : constant String :=
     "{""success"":true,""sessionId"":""s-77"",""resultSets"":[]}";

   procedure Test_Connect_Flow is
      Port : Positive;
   begin
      Loopback.Start (Plain_Ok, Port);
      declare
         Conn : Connection := Connect
           ("frostlake://127.0.0.1:" & Img (Port) & "/My_DB?schema=Sch1");
      begin
         Check_Equal (Long_Long_Integer (Loopback.Request_Count), 3,
                      "health check plus two USE statements");
         Check (Contains (Loopback.Request_Text (1), "GET /api/health"),
                "health check first");
         Check (Contains (Loopback.Request_Text (2),
                          "USE DATABASE \""My_DB\"""),
                "database quoted exactly");
         Check (not Contains (Loopback.Request_Text (2), "sessionId"),
                "first statement carries no session");
         Check (Contains (Loopback.Request_Text (3),
                          "USE SCHEMA \""Sch1\"""),
                "schema quoted exactly");
         Check (Contains (Loopback.Request_Text (3),
                          """sessionId"":""s-77"""),
                "second statement reuses the session");
         Check (Contains (Loopback.Request_Text (3),
                          """autoCommit"":true"),
                "autocommit rides along");
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Connect_Flow;

   procedure Test_Loopback_Execute is
      Port : Positive;
   begin
      Loopback.Start
        ("{""success"":true,""sessionId"":""s"",""resultSets"":[{"
         & """columns"":[{""name"":""A"",""dataType"":""NUMBER"","
         & """precision"":38,""scale"":0,""nullable"":true}],"
         & """rows"":[[5]],""rowCount"":1}]}",
         Port);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
         R : constant Result := Conn.Execute ("SELECT 5 AS A");
      begin
         Check_Equal (As_Integer (Value (R, 1, "A")), 5,
                      "value through the driver");
         Check (Contains (Loopback.Request_Text (2), "SELECT 5 AS A"),
                "statement went over the wire");
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_Execute;

   procedure Test_Loopback_Multi_Statement_Count is
      Port : Positive;
   begin
      Loopback.Start (Plain_Ok, Port);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
         Ignored : Result_Vectors.Vector;
      begin
         Conn.Execute ("SELECT 1");
         Ignored := Conn.Execute_All ("SELECT 1; SELECT 2",
                                      Multi_Statement_Count => 2);
         Conn.Execute ("SELECT 1");
         Check (not Contains (Loopback.Request_Text (2),
                              "multiStatementCount"),
                "no count unless the call asks for one");
         Check (Contains (Loopback.Request_Text (3),
                          """multiStatementCount"":2"),
                "the declared count rides on that request");
         Check (not Contains (Loopback.Request_Text (4),
                              "multiStatementCount"),
                "and on no other");
         --  Nothing alters session state to carry it.
         for I in 2 .. Loopback.Request_Count loop
            Check (not Contains (Loopback.Request_Text (I), "ALTER SESSION"),
                   "no session change behind the caller's back");
         end loop;
         --  Only No_Multi_Statement_Count stands for "not given"; any other
         --  negative is a mistake, refused before anything is sent.
         begin
            Conn.Execute ("SELECT 1", Multi_Statement_Count => -2);
            Record_Failure ("a count below zero was accepted");
         exception
            when Usage_Error =>
               null;
         end;
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_Multi_Statement_Count;

   procedure Test_Loopback_Dml_Shaping is
      Port : Positive;
   begin
      Loopback.Start
        ("{""success"":true,""sessionId"":""s"",""resultSets"":[{"
         & """columns"":[{""name"":""number of rows inserted"","
         & """dataType"":""NUMBER"",""precision"":38,""scale"":0,"
         & """nullable"":true}],""rows"":[[3]],""rowCount"":1}]}",
         Port);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
         R : constant Result := Conn.Execute ("INSERT WHATEVER");
      begin
         Check_Equal (Long_Long_Integer (R.Row_Count), 3,
                      "status row becomes an affected count");
         Check (Column_Count (R) = 0, "status columns absorbed");
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_Dml_Shaping;

   procedure Test_Loopback_Query_Error is
      Port : Positive;
   begin
      Loopback.Start
        ("{""success"":false,""sessionId"":""s"","
         & """errorMessage"":""boom""}", Port);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
      begin
         begin
            Conn.Execute ("SELECT 1");
            Record_Failure ("engine failure did not raise");
         exception
            when E : Query_Error =>
               Check_Equal (Ada.Exceptions.Exception_Message (E), "boom",
                            "engine message surfaced");
               Check_Equal (Conn.Last_Error_Message, "boom",
                            "message kept on the connection");
         end;
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_Query_Error;

   procedure Test_Loopback_Unreadable is
      Port : Positive;
   begin
      --  Status 200 keeps the health check happy — it reads only the
      --  status — and then the execute finds no protocol in the body.
      Loopback.Start ("<html>oops</html>", Port);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
      begin
         begin
            Conn.Execute ("SELECT 1");
            Record_Failure ("unreadable body did not raise");
         exception
            when E : Connection_Error =>
               Check (Contains (Ada.Exceptions.Exception_Message (E),
                                "unreadable body"),
                      "unreadable body message: "
                      & Ada.Exceptions.Exception_Message (E));
         end;
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_Unreadable;

   procedure Test_Loopback_No_Length is
      Port : Positive;
   begin
      Loopback.Start (Plain_Ok, Port, Content_Length => False);
      declare
         Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                       & Img (Port));
      begin
         Conn.Execute ("SELECT 1");
         Check (True, "read-to-EOF reply handled");
         Conn.Close;
      end;
      Loopback.Stop;
   end Test_Loopback_No_Length;

   --  A reply whose status line cannot be read is refused, and the socket
   --  that carried it goes too: GNAT.Sockets never closes one by itself.
   --  The server holds every connection open after answering, so it sees a
   --  hang-up only when the client closes its end.
   procedure Test_Loopback_Malformed_Status is
      CRLF : constant String := Character'Val (13) & Character'Val (10);

      procedure Expect_Released (Status_Line : String) is
         Calls : constant := 3;
         Port  : Positive;
      begin
         Loopback.Start_Raw (Status_Line & CRLF & CRLF, Port);
         for Call in 1 .. Calls loop
            begin
               declare
                  Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                                & Img (Port));
               begin
                  Conn.Close;
                  Record_Failure (Status_Line & ": accepted");
               end;
            exception
               when E : Connection_Error =>
                  Check_Equal
                    (Ada.Exceptions.Exception_Message (E),
                     "unintelligible response from 127.0.0.1:" & Img (Port),
                     Status_Line & ": refusal message");
            end;
         end loop;
         for Attempt in 1 .. 150 loop
            exit when Loopback.Hang_Ups = Calls;
            delay 0.02;
         end loop;
         Check_Equal (Long_Long_Integer (Loopback.Hang_Ups), Calls,
                      Status_Line & ": sockets the client closed");
         Loopback.Stop;
      end Expect_Released;

   begin
      Expect_Released ("garbage");               --  no status at all
      Expect_Released ("HTTP/1.1 two hundred");  --  no digits in it
   end Test_Loopback_Malformed_Status;

   --  Serves Head as a reply's whole header block, and expects the driver
   --  to refuse it as unreadable, naming the endpoint, and to let go of the
   --  socket that carried it.
   procedure Expect_Unintelligible (Label : String; Head : String) is
      CRLF : constant String := Character'Val (13) & Character'Val (10);
      Port : Positive;
   begin
      Loopback.Start_Raw (Head & CRLF & CRLF, Port);
      begin
         declare
            Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                          & Img (Port));
         begin
            Conn.Close;
            Record_Failure (Label & ": accepted");
         end;
      exception
         when E : Connection_Error =>
            Check_Equal
              (Ada.Exceptions.Exception_Message (E),
               "unintelligible response from 127.0.0.1:" & Img (Port),
               Label & ": refusal message");
         when E : others =>
            Record_Failure
              (Label & ": wrong exception: "
               & Ada.Exceptions.Exception_Information (E));
      end;
      for Attempt in 1 .. 150 loop
         exit when Loopback.Hang_Ups = 1;
         delay 0.02;
      end loop;
      Check_Equal (Long_Long_Integer (Loopback.Hang_Ups), 1,
                   Label & ": socket the client closed");
      Loopback.Stop;
   end Expect_Unintelligible;

   --  A number longer than its field can be is as unreadable as a missing
   --  one: the same refusal, never an overflow into an exception the driver
   --  does not document, and the socket still goes with it.
   procedure Test_Loopback_Overlong_Numbers is
      CRLF : constant String := Character'Val (13) & Character'Val (10);
      Past_Natural : constant String :=
        Ada.Strings.Fixed.Trim
          (Long_Long_Integer'Image (Long_Long_Integer (Natural'Last) + 1),
           Ada.Strings.Left);
   begin
      Expect_Unintelligible ("four-digit status", "HTTP/1.1 2000 OK");
      Expect_Unintelligible
        ("status past Natural", "HTTP/1.1 99999999999 OK");
      Expect_Unintelligible
        ("Content-Length past Natural",
         "HTTP/1.1 200 OK" & CRLF & "Content-Length: " & Past_Natural);
   end Test_Loopback_Overlong_Numbers;

   --  A Content-Length is digits with nothing but whitespace around them.
   --  Anything else is refused like an overlong one, where it was once
   --  ignored and the body read to the end of the stream; zeros in front
   --  of the digits still make a length.
   procedure Test_Loopback_Non_Digit_Length is
      CRLF : constant String := Character'Val (13) & Character'Val (10);
      Port : Positive;
   begin
      Expect_Unintelligible
        ("Content-Length 12x",
         "HTTP/1.1 200 OK" & CRLF & "Content-Length: 12x");
      Expect_Unintelligible
        ("Content-Length 1 2",
         "HTTP/1.1 200 OK" & CRLF & "Content-Length: 1 2");
      Expect_Unintelligible
        ("empty Content-Length",
         "HTTP/1.1 200 OK" & CRLF & "Content-Length:");
      --  Read to the end of the stream, this body would be "okay".
      Loopback.Start_Raw
        ("HTTP/1.1 200 OK" & CRLF
         & "Content-Length: " & Character'Val (9) & "0002 " & CRLF & CRLF
         & "okay", Port);
      declare
         Reply : constant Http.Reply := Http.Get
           ("127.0.0.1", Port, "/api/health",
            Open_Timeout => 1.0, Read_Timeout => 5.0);
      begin
         Check_Equal (Ada.Strings.Unbounded.To_String (Reply.Content), "ok",
                      "zero-padded length read as a length");
      end;
      Loopback.Stop;
   end Test_Loopback_Non_Digit_Length;

   procedure Test_Refused_Connection is
      Port : Positive;
   begin
      Loopback.Start (Plain_Ok, Port);
      Loopback.Stop;
      begin
         declare
            Conn : Connection := Connect ("frostlake://127.0.0.1:"
                                          & Img (Port));
         begin
            Conn.Close;
            Record_Failure ("closed port accepted");
         end;
      exception
         when E : Connection_Error =>
            Check (Contains (Ada.Exceptions.Exception_Message (E),
                             "cannot reach"),
                   "refused connection message");
      end;
   end Test_Refused_Connection;

   --  A host name the resolver cannot place is as unreachable as a closed
   --  port, and the refusal names the endpoint.  The .invalid domain is
   --  reserved never to resolve.
   procedure Test_Unresolvable_Host is
   begin
      declare
         Conn : Connection :=
           Connect ("frostlake://nonexistent.invalid:18099");
      begin
         Conn.Close;
         Record_Failure ("unresolvable host accepted");
      end;
   exception
      when E : Connection_Error =>
         Check (Contains (Ada.Exceptions.Exception_Message (E),
                          "cannot reach nonexistent.invalid:18099"),
                "unresolvable host message: "
                & Ada.Exceptions.Exception_Message (E));
   end Test_Unresolvable_Host;

   ---------------------------------------------------------------
   --  Session lifetime, against a scripted server: requireSession
   --  once the engine is known to honour it, recovery from a session
   --  the engine no longer holds, and the session released on close
   ---------------------------------------------------------------

   Health : constant String := "{""status"":""healthy"",""activeSessions"":0}";

   --  Answers from an engine that reports newSession (0.1.0 and later).
   S1_New   : constant String :=
     "{""success"":true,""sessionId"":""s1"",""newSession"":true,"
     & """resultSets"":[]}";
   S1       : constant String :=
     "{""success"":true,""sessionId"":""s1"",""newSession"":false,"
     & """resultSets"":[]}";
   S2_New   : constant String :=
     "{""success"":true,""sessionId"":""s2"",""newSession"":true,"
     & """resultSets"":[]}";
   S2       : constant String :=
     "{""success"":true,""sessionId"":""s2"",""newSession"":false,"
     & """resultSets"":[]}";
   S2_Seven : constant String :=
     "{""success"":true,""sessionId"":""s2"",""newSession"":false,"
     & """resultSets"":[{""columns"":[{""name"":""N"",""dataType"":"
     & """NUMBER"",""precision"":38,""scale"":0}],""rows"":[[7]]}]}";
   S3_New   : constant String :=
     "{""success"":true,""sessionId"":""s3"",""newSession"":true,"
     & """resultSets"":[]}";
   S3       : constant String :=
     "{""success"":true,""sessionId"":""s3"",""newSession"":false,"
     & """resultSets"":[]}";

   --  The 404 a request that requires its session gets once the engine no
   --  longer holds it: nothing ran.
   Gone_S1 : constant String :=
     "{""success"":false,""errorMessage"":""Session 's1' does not exist or"
     & " has expired."",""sessionId"":null,""newSession"":false,"
     & """resultSets"":[]}";
   Gone_S2 : constant String :=
     "{""success"":false,""errorMessage"":""Session 's2' does not exist or"
     & " has expired."",""sessionId"":null,""newSession"":false,"
     & """resultSets"":[]}";

   --  What DELETE /api/sessions/{id} answers for a session the engine held.
   Released : constant String :=
     "{""success"":true,""sessionId"":null,""newSession"":false,"
     & """resultSets"":[]}";

   --  An answer from an engine that predates newSession (0.0.7).
   Legacy : constant String :=
     "{""success"":true,""sessionId"":""s1"",""resultSets"":[]}";

   Use_App : constant String := "USE DATABASE \""APP\""";

   function App_Dsn (Port : Positive; Query : String := "") return String is
     ("frostlake://127.0.0.1:" & Img (Port) & "/APP" & Query);

   function Bare_Dsn (Port : Positive; Query : String := "") return String is
     ("frostlake://127.0.0.1:" & Img (Port) & Query);

   procedure Expect_Session_Lost
     (Conn   : in out Connection;
      Sql    : String;
      Reason : String;
      Label  : String) is
   begin
      Conn.Execute (Sql);
      Record_Failure (Label & ": no Session_Lost_Error");
   exception
      when E : Session_Lost_Error =>
         Check (Contains (Ada.Exceptions.Exception_Message (E), Reason),
                Label & ": " & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Record_Failure
           (Label & ": wrong exception: "
            & Ada.Exceptions.Exception_Information (E));
   end Expect_Session_Lost;

   procedure Test_Session_Flag_Waits_For_The_Engine is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE, which starts the session
      Loopback.Add_Reply (200, S1);        --  SELECT 1
      Loopback.Add_Reply (200, Released);  --  DELETE, on close
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Execute ("SELECT 1");
         Conn.Close;
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 4,
                   "one DELETE, however often closed");
      --  Nothing is known before the first answer, so the request that
      --  starts the session carries neither an id nor the flag.
      Check (Contains (Loopback.Request_Text (2), Use_App),
             "the scope first");
      Check (not Contains (Loopback.Request_Text (2), "sessionId"),
             "no id before the first answer");
      Check (not Contains (Loopback.Request_Text (2), "requireSession"),
             "no flag before the first answer");
      --  That answer carried newSession, so every request naming the
      --  session requires it from then on.
      Check (Contains (Loopback.Request_Text (3),
                       """sessionId"":""s1"",""requireSession"":true"),
             "the session required once the engine said it keeps them");
      Check (Contains (Loopback.Request_Text (4),
                       "DELETE /api/sessions/s1 HTTP/1.1"),
             "close released the session");
      Loopback.Stop;
   end Test_Session_Flag_Waits_For_The_Engine;

   procedure Test_Older_Engine_Gets_No_Session_Flag is
      Port : Positive;
   begin
      --  Engines before 0.1.0 answer no newSession and know neither
      --  requireSession nor DELETE /api/sessions: their parser may refuse a
      --  field it does not know.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, Legacy);  --  USE
      Loopback.Add_Reply (200, Legacy);  --  SELECT 1
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Execute ("SELECT 1");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 3,
                   "no DELETE to an older engine");
      Check (Contains (Loopback.Request_Text (3), """sessionId"":""s1"""),
             "the session named");
      Check (not Contains (Loopback.Request_Text (3), "requireSession"),
             "an older engine is never sent requireSession");
      Loopback.Stop;
   end Test_Older_Engine_Gets_No_Session_Flag;

   procedure Test_Lost_Session_Is_Replaced_Once is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (200, S1);        --  CREATE TABLE, which is no context
      Loopback.Add_Reply (404, Gone_S1);   --  SELECT 7: the session is gone
      Loopback.Add_Reply (200, S2_New);    --  USE, in a fresh session
      Loopback.Add_Reply (200, S2_Seven);  --  SELECT 7, once more
      Loopback.Add_Reply (200, Released);
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Execute ("CREATE TABLE t (a INT)");
         declare
            R : constant Result := Conn.Execute ("SELECT 7 AS N");
         begin
            Check_Equal (As_Integer (Value (R, 1, "N")), 7,
                         "the statement sent once more answered");
         end;
         Check_Equal (Conn.Session, "s2", "the fresh session is the one held");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 7,
                   "requests of a recovered statement");
      --  The scope went onto a fresh session, named by no id, and the
      --  statement followed it there.
      Check (Contains (Loopback.Request_Text (5), Use_App)
               and then not Contains (Loopback.Request_Text (5), "sessionId"),
             "the scope onto a fresh session");
      Check (Contains (Loopback.Request_Text (6), "SELECT 7 AS N")
               and then Contains
                 (Loopback.Request_Text (6),
                  """sessionId"":""s2"",""requireSession"":true"),
             "the statement once more, in the fresh session");
      Check (Contains (Loopback.Request_Text (7), "DELETE /api/sessions/s2 "),
             "the fresh session released on close");
      Loopback.Stop;
   end Test_Lost_Session_Is_Replaced_Once;

   procedure Test_Second_Loss_Raises is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (404, Gone_S1);   --  SELECT 1
      Loopback.Add_Reply (200, S2_New);    --  USE, in a fresh session
      Loopback.Add_Reply (404, Gone_S2);   --  SELECT 1, refused again
      Loopback.Add_Reply (200, S3_New);    --  the next statement starts over
      Loopback.Add_Reply (200, S3);        --  SELECT 2
      Loopback.Add_Reply (200, Released);
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Expect_Session_Lost (Conn, "SELECT 1", "just started",
                              "a second refusal");
         Check (not Conn.Is_Closed, "the connection carries on");
         Conn.Execute ("SELECT 2");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 8,
                   "requests of a twice-refused statement");
      Check (Contains (Loopback.Request_Text (6), Use_App)
               and then not Contains (Loopback.Request_Text (6), "sessionId"),
             "the next statement starts a fresh session on the scope");
      Loopback.Stop;
   end Test_Second_Loss_Raises;

   procedure Test_Lost_Transaction_Raises is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (200, S1);        --  BEGIN
      Loopback.Add_Reply (404, Gone_S1);   --  INSERT: the session is gone
      Loopback.Add_Reply (200, S2_New);    --  the next statement starts over
      Loopback.Add_Reply (200, S2);        --  SELECT 1
      Loopback.Add_Reply (200, Released);
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Begin_Transaction;
         Check (Conn.In_Transaction, "BEGIN opened a transaction");
         Expect_Session_Lost (Conn, "INSERT INTO t VALUES (1)", "transaction",
                              "a lost transaction");
         Check (not Conn.In_Transaction, "the transaction went with it");
         Conn.Execute ("SELECT 1");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 7,
                   "requests around a lost transaction");
      --  The INSERT was not sent again, and the next statement started
      --  over on the DSN's scope with autocommit back on.
      Check (Contains (Loopback.Request_Text (4), "INSERT INTO t VALUES (1)"),
             "the INSERT sent once");
      Check (Contains (Loopback.Request_Text (5), Use_App)
               and then not Contains (Loopback.Request_Text (5), "sessionId")
               and then Contains (Loopback.Request_Text (5),
                                  """autoCommit"":true"),
             "a fresh session on the scope, autocommit back on");
      Check (Contains (Loopback.Request_Text (6), "SELECT 1")
               and then Contains (Loopback.Request_Text (6),
                                  """autoCommit"":true"),
             "the next statement autocommits");
      Loopback.Stop;
   end Test_Lost_Transaction_Raises;

   procedure Test_Statement_Transaction_Is_Tracked is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (200, S1);        --  BEGIN TRANSACTION
      Loopback.Add_Reply (200, S1);        --  COMMIT
      Loopback.Add_Reply (200, S1);        --  START TRANSACTION
      Loopback.Add_Reply (404, Gone_S1);   --  INSERT: the session is gone
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Execute ("BEGIN TRANSACTION");
         Check (Conn.In_Transaction, "BEGIN TRANSACTION opens one");
         Conn.Execute ("COMMIT");
         Check (not Conn.In_Transaction, "COMMIT ends it");
         Conn.Execute ("START TRANSACTION");
         Check (Conn.In_Transaction, "START TRANSACTION opens one");
         Expect_Session_Lost (Conn, "INSERT INTO t VALUES (1)", "transaction",
                              "a lost statement transaction");
         Check (not Conn.In_Transaction, "and it went with the session");
         --  The session is gone, so closing has nothing to release.
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 6,
                   "nothing released for a session already gone");
      Loopback.Stop;
   end Test_Statement_Transaction_Is_Tracked;

   procedure Test_Lost_Context_Raises is
      --  Each of these leaves something behind that a fresh session would
      --  not have, so re-running the next statement in one would run it
      --  somewhere else.
      procedure After (Context : String) is
         Port : Positive;
      begin
         Loopback.Start_Script (Port);
         Loopback.Add_Reply (200, Health);
         Loopback.Add_Reply (200, S1_New);    --  USE
         Loopback.Add_Reply (200, S1);        --  the context
         Loopback.Add_Reply (404, Gone_S1);   --  SELECT: the session is gone
         Loopback.Add_Reply (200, S2_New);    --  the next statement starts over
         Loopback.Add_Reply (200, S2);        --  SELECT 1
         Loopback.Add_Reply (200, Released);
         declare
            Conn : Connection := Connect (App_Dsn (Port));
         begin
            Conn.Execute (Context);
            Expect_Session_Lost (Conn, "SELECT * FROM t", "context",
                                 "lost after " & Context);
            Conn.Execute ("SELECT 1");
            Conn.Close;
         end;
         Check_Equal (Long_Long_Integer (Loopback.Request_Count), 7,
                      "requests after " & Context);
         Check (Contains (Loopback.Request_Text (4), "SELECT * FROM t"),
                "the statement sent once after " & Context);
         Check (Contains (Loopback.Request_Text (5), Use_App)
                  and then not Contains (Loopback.Request_Text (5),
                                         "sessionId"),
                "a fresh session on the scope after " & Context);
         Loopback.Stop;
      end After;
   begin
      After ("USE SCHEMA OTHER");
      After ("SET v = 1");
      After ("ALTER SESSION SET TIMEZONE = 'UTC'");
      After ("CREATE TEMPORARY TABLE scratch (a INT)");
   end Test_Lost_Context_Raises;

   procedure Test_Replaced_Session_Gets_Its_Scope_Back is
      Port : Positive;
   begin
      --  An engine that ran a request in a fresh session in place of the
      --  one it named says so with newSession: true; what the old one held
      --  is gone.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (200, S1_New);    --  SELECT 1, in a fresh session
      Loopback.Add_Reply (200, S1);        --  USE, again
      Loopback.Add_Reply (200, S1);        --  SELECT 2
      Loopback.Add_Reply (200, Released);
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         Conn.Execute ("SELECT 1");
         Conn.Execute ("SELECT 2");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 6,
                   "requests around a replaced session");
      Check (Contains (Loopback.Request_Text (4), Use_App),
             "the scope back on first");
      Check (Contains (Loopback.Request_Text (5), "SELECT 2"),
             "then the next statement");
      Loopback.Stop;
   end Test_Replaced_Session_Gets_Its_Scope_Back;

   procedure Test_Idle_Rescope_Is_For_Older_Engines is
      Port : Positive;
   begin
      --  An engine that answers newSession refuses a lapsed session instead
      --  of rebuilding it, and the refusal is recovered from where it lands:
      --  no USE goes ahead of a statement on a hunch, however long the
      --  connection idled.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE
      Loopback.Add_Reply (200, S1);        --  SELECT 1
      Loopback.Add_Reply (200, S1);        --  SELECT 2
      Loopback.Add_Reply (200, Released);
      declare
         Conn : Connection :=
           Connect (App_Dsn (Port, "?session_idle_limit=0.01"));
      begin
         Conn.Execute ("SELECT 1");
         delay 0.05;
         Conn.Execute ("SELECT 2");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 5,
                   "no USE on a hunch to an engine that keeps sessions");
      Check (Contains (Loopback.Request_Text (4), "SELECT 2"),
             "SELECT 2 straight after SELECT 1");
      Loopback.Stop;

      --  An older engine rebuilds a lapsed session under the same id
      --  without a word, so past the limit the scope goes back on first.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      for Reply in 1 .. 6 loop
         Loopback.Add_Reply (200, Legacy);
      end loop;
      declare
         Conn : Connection :=
           Connect (App_Dsn (Port, "?session_idle_limit=0.01"));
      begin
         Conn.Execute ("SELECT 1");
         delay 0.05;
         Conn.Execute ("SELECT 2");
         Conn.Close;
      end;
      declare
         Last : constant Natural := Loopback.Request_Count;
      begin
         Check (Last >= 5
                  and then Contains (Loopback.Request_Text (Last), "SELECT 2")
                  and then Contains (Loopback.Request_Text (Last - 1),
                                     Use_App),
                "an older engine's idle session gets the scope back");
      end;
      Loopback.Stop;
   end Test_Idle_Rescope_Is_For_Older_Engines;

   procedure Test_Scope_Exit_Releases_The_Session is
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  SELECT 1
      Loopback.Add_Reply (200, Released);  --  DELETE, as the scope ends
      declare
         Conn : Connection := Connect (Bare_Dsn (Port));
      begin
         Conn.Execute ("SELECT 1");
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 3,
                   "a connection going out of scope releases its session");
      Check (Contains (Loopback.Request_Text (3), "DELETE /api/sessions/s1 "),
             "the DELETE names the session");
      Loopback.Stop;
   end Test_Scope_Exit_Releases_The_Session;

   procedure Test_Refused_Scope_Releases_The_Session is
      Port : Positive;
   begin
      --  The engine refused the USE, but in a session it started for it.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply
        (200,
         "{""success"":false,""errorMessage"":""Database 'APP' does not exist"
         & " or not authorized."",""sessionId"":""s9"",""newSession"":true,"
         & """resultSets"":[]}");
      Loopback.Add_Reply (200, Released);
      begin
         declare
            Conn : Connection := Connect (App_Dsn (Port));
         begin
            Conn.Close;
            Record_Failure ("a refused scope connected");
         end;
      exception
         when Query_Error =>
            null;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 3,
                   "a refused connect still releases the session it started");
      Check (Contains (Loopback.Request_Text (3), "DELETE /api/sessions/s9 "),
             "the DELETE names that session");
      Loopback.Stop;
   end Test_Refused_Scope_Releases_The_Session;

   procedure Test_Closing_Never_Raises is
      use type Ada.Calendar.Time;

      --  Whatever the DELETE meets, closing returns quietly, within its
      --  bound: here the DSN's one-second read timeout, shorter than the
      --  five seconds closing would otherwise allow itself.
      procedure Against (Status : Natural; Content : String; Label : String)
      is
         Port    : Positive;
         Started : Ada.Calendar.Time;
      begin
         Loopback.Start_Script (Port);
         Loopback.Add_Reply (200, Health);
         Loopback.Add_Reply (200, S1_New);    --  SELECT 1
         Loopback.Add_Reply (Status, Content);
         declare
            Conn : Connection := Connect (Bare_Dsn (Port, "?read_timeout=1"));
         begin
            Conn.Execute ("SELECT 1");
            Started := Ada.Calendar.Clock;
            Conn.Close;
            Check (Ada.Calendar.Clock - Started < 4.0,
                   Label & ": closing returned within its bound");
            Check (Conn.Is_Closed, Label & ": closed");
         end;
         Check_Equal (Long_Long_Integer (Loopback.Request_Count), 3,
                      Label & ": the DELETE was sent");
         Check (Contains (Loopback.Request_Text (3), "DELETE /api/sessions/s1 "),
                Label & ": the DELETE names the session");
         Loopback.Stop;
      end Against;

      Port : Positive;
   begin
      Against
        (404,
         "{""success"":false,""errorMessage"":""Session 's1' does not exist"
         & " or has expired."",""sessionId"":null,""resultSets"":[]}",
         "a 404");
      Against (405, "", "a 405");
      Against (Loopback.Hang_Up, "", "a hang-up");
      Against (Loopback.Silence, "", "silence");

      --  Nothing listening at all: the release cannot even connect.
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);
      declare
         Conn : Connection := Connect (Bare_Dsn (Port, "?read_timeout=1"));
      begin
         Conn.Execute ("SELECT 1");
         Loopback.Stop;
         Conn.Close;
         Check (Conn.Is_Closed, "nothing listening: closed");
      end;
   end Test_Closing_Never_Raises;

   ---------------------------------------------------------------
   --  A failed Begin_Transaction, against a scripted server: BEGIN
   --  goes out with autocommit off, but only a BEGIN that ran turns
   --  the connection's autocommit off
   ---------------------------------------------------------------

   Begin_Refused : constant String :=
     "{""success"":false,""errorMessage"":""BEGIN refused"","
     & """sessionId"":""s1"",""newSession"":false,""resultSets"":[]}";

   procedure Test_Failed_Begin_Keeps_Autocommit is
      --  After a BEGIN that failed, the next statement still autocommits
      --  instead of running in an implicit transaction that nobody opened
      --  and that closing would roll back unseen.
      procedure Against (Status : Natural; Content : String; Label : String)
      is
         Port : Positive;
      begin
         Loopback.Start_Script (Port);
         Loopback.Add_Reply (200, Health);
         Loopback.Add_Reply (200, S1_New);    --  SELECT 1
         Loopback.Add_Reply (Status, Content); --  BEGIN
         Loopback.Add_Reply (200, S1);        --  INSERT
         Loopback.Add_Reply (200, Released);  --  DELETE, on close
         declare
            Conn : Connection := Connect (Bare_Dsn (Port));
         begin
            Conn.Execute ("SELECT 1");
            begin
               Conn.Begin_Transaction;
               Record_Failure (Label & ": the BEGIN did not fail");
            exception
               when Query_Error | Connection_Error =>
                  null;
            end;
            Check (not Conn.In_Transaction,
                   Label & ": no transaction was opened");
            Conn.Execute ("INSERT INTO t VALUES (1)");
            Conn.Close;
         end;
         Check_Equal (Long_Long_Integer (Loopback.Request_Count), 5,
                      Label & ": requests around a failed begin");
         Check (Contains (Loopback.Request_Text (3), "BEGIN")
                  and then Contains (Loopback.Request_Text (3),
                                     """autoCommit"":false"),
                Label & ": BEGIN still goes out with autocommit off");
         Check (Contains (Loopback.Request_Text (4), "INSERT")
                  and then Contains (Loopback.Request_Text (4),
                                     """autoCommit"":true"),
                Label & ": the statement after a failed begin autocommits");
         Loopback.Stop;
      end Against;
   begin
      Against (200, Begin_Refused, "a refused BEGIN");
      Against (502, "<html>Bad Gateway</html>", "an unreadable answer");
      Against (Loopback.Hang_Up, "", "a hang-up");
   end Test_Failed_Begin_Keeps_Autocommit;

   procedure Test_Begin_Behind_Refused_Use_Keeps_Autocommit is
      --  An older engine's idle session gets the DSN's scope back before the
      --  next statement, a BEGIN included; refused, that USE fails the begin
      --  before any BEGIN is sent.
      Refused_Use : constant String :=
        "{""success"":false,""errorMessage"":""Database 'APP' does not"
        & " exist or not authorized."",""sessionId"":null,"
        & """resultSets"":[]}";
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, Legacy);        --  USE, on connect
      Loopback.Add_Reply (500, Refused_Use);   --  USE, ahead of the BEGIN
      Loopback.Add_Reply (200, Legacy);        --  USE, ahead of the INSERT
      Loopback.Add_Reply (200, Legacy);        --  INSERT
      declare
         Conn : Connection :=
           Connect (App_Dsn (Port, "?session_idle_limit=0.01"));
      begin
         delay 0.05;
         begin
            Conn.Begin_Transaction;
            Record_Failure ("a refused USE did not fail the begin");
         exception
            when Query_Error =>
               null;
         end;
         Check (not Conn.In_Transaction, "no transaction was opened");
         delay 0.05;
         Conn.Execute ("INSERT INTO t VALUES (1)");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 5,
                   "requests around a begin behind a refused USE");
      for Index in 1 .. Loopback.Request_Count loop
         Check (not Contains (Loopback.Request_Text (Index), "BEGIN"),
                "no BEGIN went out, request" & Natural'Image (Index));
      end loop;
      for Index in 3 .. 5 loop
         Check (Contains (Loopback.Request_Text (Index), """autoCommit"":true"),
                "request" & Natural'Image (Index) & " autocommits");
      end loop;
      Check (Contains (Loopback.Request_Text (5), "INSERT"),
             "the statement came last");
      Loopback.Stop;
   end Test_Begin_Behind_Refused_Use_Keeps_Autocommit;

   procedure Test_Begin_Its_Fresh_Session_Refuses_Keeps_Autocommit is
      --  The session was gone under the BEGIN, so the scope went onto a fresh
      --  session and the BEGIN once more, still with autocommit off — and
      --  that one was refused.
      Port : Positive;
   begin
      Loopback.Start_Script (Port);
      Loopback.Add_Reply (200, Health);
      Loopback.Add_Reply (200, S1_New);    --  USE, on connect
      Loopback.Add_Reply (404, Gone_S1);   --  BEGIN: the session is gone
      Loopback.Add_Reply (200, S2_New);    --  USE, in a fresh session
      Loopback.Add_Reply
        (200,
         "{""success"":false,""errorMessage"":""BEGIN refused"","
         & """sessionId"":""s2"",""newSession"":false,""resultSets"":[]}");
      Loopback.Add_Reply (200, S2);        --  INSERT
      Loopback.Add_Reply (200, Released);  --  DELETE, on close
      declare
         Conn : Connection := Connect (App_Dsn (Port));
      begin
         begin
            Conn.Begin_Transaction;
            Record_Failure ("a refused BEGIN did not fail the begin");
         exception
            when Query_Error =>
               null;
         end;
         Check (not Conn.In_Transaction, "no transaction was opened");
         Conn.Execute ("INSERT INTO t VALUES (1)");
         Conn.Close;
      end;
      Check_Equal (Long_Long_Integer (Loopback.Request_Count), 7,
                   "requests around a BEGIN refused in a fresh session");
      Check (Contains (Loopback.Request_Text (5), "BEGIN")
               and then Contains (Loopback.Request_Text (5),
                                  """autoCommit"":false"),
             "the BEGIN went again with autocommit off");
      Check (Contains (Loopback.Request_Text (6), "INSERT")
               and then Contains (Loopback.Request_Text (6),
                                  """autoCommit"":true"),
             "the statement after the failed begin autocommits");
      Loopback.Stop;
   end Test_Begin_Its_Fresh_Session_Refuses_Keeps_Autocommit;

   ---------------------------------------------------------------
   --  Integration: a real DatabaseHttpServer
   ---------------------------------------------------------------

   function Free_Port return Positive is
      use GNAT.Sockets;
      Probe   : Socket_Type;
      Address : Sock_Addr_Type;
   begin
      Create_Socket (Probe);
      Bind_Socket
        (Probe,
         (Family => Family_Inet,
          Addr   => Inet_Addr ("127.0.0.1"),
          Port   => 0));
      Address := Get_Socket_Name (Probe);
      Close_Socket (Probe);
      return Positive (Address.Port);
   end Free_Port;

   procedure Run_Integration is
      Classpath : constant String :=
        Ada.Environment_Variables.Value ("FROSTLAKE_CLASSPATH", "");
   begin
      if Classpath = "" then
         Note ("integration: skipped (FROSTLAKE_CLASSPATH not set)");
         return;
      end if;
      declare
         use GNAT.OS_Lib;
         Java_Home : constant String :=
           Ada.Environment_Variables.Value ("JAVA_HOME", "");
         Java : constant String :=
           (if Java_Home /= "" then Java_Home & "/bin/java" else "java");
         Java_Path : String_Access :=
           (if Java_Home /= "" then new String'(Java)
            else Locate_Exec_On_Path ("java"));
         Port : constant Positive := Free_Port;
         Args : Argument_List (1 .. 4);
         Pid  : Process_Id;
         Healthy : Boolean := False;
      begin
         if Java_Path = null then
            Record_Failure ("integration: no java on PATH and no"
                            & " JAVA_HOME");
            return;
         end if;
         Args (1) := new String'("-cp");
         Args (2) := new String'(Classpath);
         Args (3) := new String'("dev.frostlake.http.DatabaseHttpServer");
         Args (4) := new String'(Img (Port));
         Pid := Non_Blocking_Spawn
           (Program_Name => Java_Path.all,
            Args         => Args,
            Output_File  => "db-engine.log",
            Err_To_Out   => True);
         for A of Args loop
            Free (A);
         end loop;
         Free (Java_Path);
         if Pid = Invalid_Pid then
            Record_Failure ("integration: could not start the server");
            return;
         end if;
         for Attempt in 1 .. 100 loop
            begin
               declare
                  Reply : constant Http.Reply := Http.Get
                    ("127.0.0.1", Port, "/api/health",
                     Open_Timeout => 1.0, Read_Timeout => 5.0);
               begin
                  if Reply.Status in 200 .. 299 then
                     Healthy := True;
                  end if;
               end;
            exception
               when Connection_Error =>
                  null;
            end;
            exit when Healthy;
            delay 0.2;
         end loop;
         if not Healthy then
            Record_Failure
              ("integration: server never became healthy"
               & " — see db-engine.log");
         else
            Integration_Tests.Run ("frostlake://127.0.0.1:" & Img (Port));
         end if;
         Kill (Pid, Hard_Kill => True);
      end;
   end Run_Integration;

begin
   Note ("Frostlake Ada driver test suite, driver version "
         & Frostlake.Version);

   Guarded ("quote identifier", Test_Quote_Identifier'Access);
   Guarded ("format literal", Test_Format_Literal'Access);
   Guarded ("substitute", Test_Substitute'Access);
   Guarded ("selects session state", Test_Selects_Session_State'Access);
   Guarded ("touches session", Test_Touches_Session'Access);
   Guarded ("transaction effect", Test_Transaction_Effect'Access);
   Guarded ("escape json", Test_Escape_Json'Access);
   Guarded ("build request", Test_Build_Request'Access);
   Guarded ("parse success", Test_Parse_Success_Response'Access);
   Guarded ("parse column length", Test_Parse_Column_Length'Access);
   Guarded ("parse shuffled", Test_Parse_Shuffled_Response'Access);
   Guarded ("parse new session", Test_Parse_New_Session'Access);
   Guarded ("parse error", Test_Parse_Error_Response'Access);
   Guarded ("parse garbage", Test_Parse_Garbage'Access);
   Guarded ("retype", Test_Retype'Access);
   Guarded ("wire temporals", Test_Wire_Temporals'Access);
   Guarded ("numeric text", Test_Numeric_Text'Access);
   Guarded ("dml shapes", Test_Dml_Shapes'Access);
   Guarded ("dsn errors", Test_Dsn_Errors'Access);
   Guarded ("connect flow", Test_Connect_Flow'Access);
   Guarded ("loopback execute", Test_Loopback_Execute'Access);
   Guarded ("loopback multi statement count",
            Test_Loopback_Multi_Statement_Count'Access);
   Guarded ("loopback dml shaping", Test_Loopback_Dml_Shaping'Access);
   Guarded ("loopback query error", Test_Loopback_Query_Error'Access);
   Guarded ("loopback unreadable", Test_Loopback_Unreadable'Access);
   Guarded ("loopback no length", Test_Loopback_No_Length'Access);
   Guarded ("loopback malformed status",
            Test_Loopback_Malformed_Status'Access);
   Guarded ("loopback overlong numbers",
            Test_Loopback_Overlong_Numbers'Access);
   Guarded ("loopback non-digit length",
            Test_Loopback_Non_Digit_Length'Access);
   Guarded ("refused connection", Test_Refused_Connection'Access);
   Guarded ("unresolvable host", Test_Unresolvable_Host'Access);
   Guarded ("session flag waits for the engine",
            Test_Session_Flag_Waits_For_The_Engine'Access);
   Guarded ("older engine gets no session flag",
            Test_Older_Engine_Gets_No_Session_Flag'Access);
   Guarded ("lost session is replaced once",
            Test_Lost_Session_Is_Replaced_Once'Access);
   Guarded ("second loss raises", Test_Second_Loss_Raises'Access);
   Guarded ("lost transaction raises", Test_Lost_Transaction_Raises'Access);
   Guarded ("statement transaction is tracked",
            Test_Statement_Transaction_Is_Tracked'Access);
   Guarded ("lost context raises", Test_Lost_Context_Raises'Access);
   Guarded ("replaced session gets its scope back",
            Test_Replaced_Session_Gets_Its_Scope_Back'Access);
   Guarded ("idle rescope is for older engines",
            Test_Idle_Rescope_Is_For_Older_Engines'Access);
   Guarded ("scope exit releases the session",
            Test_Scope_Exit_Releases_The_Session'Access);
   Guarded ("refused scope releases the session",
            Test_Refused_Scope_Releases_The_Session'Access);
   Guarded ("closing never raises", Test_Closing_Never_Raises'Access);
   Guarded ("failed begin keeps autocommit",
            Test_Failed_Begin_Keeps_Autocommit'Access);
   Guarded ("begin behind a refused USE keeps autocommit",
            Test_Begin_Behind_Refused_Use_Keeps_Autocommit'Access);
   Guarded ("begin its fresh session refuses keeps autocommit",
            Test_Begin_Its_Fresh_Session_Refuses_Keeps_Autocommit'Access);
   Loopback.Stop;

   Run_Integration;
   Corpus_Tests.Run;

   Note (Img (Passed) & " passed," & Natural'Image (Failed) & " failed,"
         & Natural'Image (Skipped) & " skipped");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Frostlake_Tests;
