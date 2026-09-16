--  The driver's test suite.  The unit half runs with no server and no
--  JVM — the wire pieces directly, the whole driver against a loopback
--  HTTP server.  The integration half boots a real DatabaseHttpServer
--  from FROSTLAKE_CLASSPATH and skips itself when that is unset.

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;
with GNAT.Sockets;

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
   Guarded ("escape json", Test_Escape_Json'Access);
   Guarded ("build request", Test_Build_Request'Access);
   Guarded ("parse success", Test_Parse_Success_Response'Access);
   Guarded ("parse column length", Test_Parse_Column_Length'Access);
   Guarded ("parse shuffled", Test_Parse_Shuffled_Response'Access);
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
   Guarded ("refused connection", Test_Refused_Connection'Access);
   Loopback.Stop;

   Run_Integration;

   Note (Img (Passed) & " passed," & Natural'Image (Failed) & " failed,"
         & Natural'Image (Skipped) & " skipped");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Frostlake_Tests;
