pragma Ada_2022;

--  The JSON wire protocol of POST /api/execute: building the request body
--  and reading the response.  Public so the test suite can exercise it
--  without a server; not otherwise part of the driver's stable API.

package Frostlake.Wire is

   --  The response body could not be read as the protocol's JSON.  The
   --  connection layer wraps this into Connection_Error with the HTTP
   --  status attached.
   Parse_Error : exception;

   type Response is record
      Success           : Boolean := False;
      Session_Id        : Ada.Strings.Unbounded.Unbounded_String;
      Has_Session_Id    : Boolean := False;
      Error_Message     : Ada.Strings.Unbounded.Unbounded_String;
      Has_Error_Message : Boolean := False;
      Result_Sets       : Result_Vectors.Vector;
   end record;

   function Build_Execute_Request
     (Sql                   : String;
      Session_Id            : String;
      Auto_Commit           : Boolean;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return String;
   --  {"sql":...,"autoCommit":...} plus "sessionId" when one is held and
   --  "multiStatementCount" when this request declares one.  Left at
   --  No_Multi_Statement_Count the field is absent altogether, which is
   --  the body the server has always been sent.

   function Parse_Response (Content : String) return Response;
   --  Reads the whole response object.  Cells are typed from their
   --  column's dataType and scale; unknown fields are skipped so a newer
   --  server stays readable.

   function Escape_Json (Text : String) return String;
   --  The JSON string-literal body for Text (no surrounding quotes):
   --  quote, backslash and control characters escaped, everything else —
   --  UTF-8 included — passed through.

   function Retype
     (Raw       : Cell;
      Data_Type : String;
      Scale     : Natural) return Cell;
   --  Places a freshly parsed JSON cell against its column: DATE and
   --  TIMESTAMP* text becomes a Date/Timestamp cell, BINARY hex becomes
   --  bytes, VARIANT/OBJECT/ARRAY text is marked as JSON, FLOAT-family
   --  numbers become Float_Kind, and a scale-0 decimal with integral
   --  digits becomes Integer_Kind.  Anything unplaceable is returned
   --  unchanged rather than guessed at.

   function Is_Dml_Status (Columns : Column_Vectors.Vector) return Boolean;
   --  Whether a result set is a DML status row rather than data.  The
   --  protocol carries no statement type, so this goes by shape: DML
   --  answers with columns that are all "number of ..." counters.

   function Dml_Row_Count
     (Columns : Column_Vectors.Vector;
      Row     : Cell_Vectors.Vector) return Natural;
   --  Total rows affected: the sum of the "number of rows ..." counters.
   --  "number of multi-joined rows updated" is a diagnostic sub-count of
   --  rows already counted as updated, so it is left out.

   procedure Parse_Wire_Date
     (Text  : String;
      Value : out Date_Value;
      Ok    : out Boolean);
   --  "YYYY-MM-DD".

   procedure Parse_Wire_Timestamp
     (Text  : String;
      Value : out Timestamp_Value;
      Ok    : out Boolean);
   --  "YYYY-MM-DD HH:MM:SS[.fract]" with an optional " +HHMM" / "+HH:MM"
   --  / "Z" offset; a 'T' separator is accepted too.

   procedure To_Integer_If_Integral
     (Text  : String;
      Value : out Long_Long_Integer;
      Ok    : out Boolean);
   --  Reads a numeric text whose value is a whole number — "5", "-5",
   --  "5.000" — into a Long_Long_Integer.  Ok is False when the text has
   --  a real fraction, an exponent, or does not fit.

   function To_Long_Float (Number_Text : String) return Long_Float;
   --  A JSON number as Long_Float.  JSON allows "1e5" where Ada's 'Value
   --  demands "1.0e5", so this normalizes before converting; raises
   --  Constraint_Error when the text is not a number at all.

end Frostlake.Wire;
