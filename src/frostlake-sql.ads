--  Client-side SQL assembly: identifier quoting, literal rendering, and
--  ?-placeholder substitution.  Public so the test suite (and a caller
--  building SQL by hand) can reach it; the shapes here mirror Frostlake's
--  other drivers.

package Frostlake.Sql is

   function Quote_Identifier (Name : String) return String;
   --  Always quoted.  Leaving "unambiguous" names bare lets through ones
   --  that cannot legally appear unquoted — 1ABC starts with a digit,
   --  SELECT is reserved — and quoting costs nothing: "NAME" and NAME name
   --  the same object.  An empty name raises Usage_Error.

   function Format_Literal (Value : Cell) return String;
   --  The SQL literal for one bind value.  Timestamps carrying an offset
   --  become '...'::TIMESTAMP_TZ, offset-less ones '...'::TIMESTAMP_NTZ;
   --  dates '...'::DATE; binary X'HEX'; variants PARSE_JSON('...').  A
   --  non-finite Float raises Usage_Error.

   function Substitute (Sql : String; Binds : Bind_Array) return String;
   --  Replaces each ? outside of '...' and "..." literals, -- and //
   --  line comments, /* */ block comments and $$...$$ bodies with the
   --  next bind's literal.  Raises Usage_Error when placeholders outrun
   --  the binds; unused binds are not an error.

   function Selects_Session_State (Sql : String) return Boolean;
   --  Whether the statement is a USE — the caller picking their own
   --  database, schema, warehouse or role for the session.

   function Is_Numeric_Literal (Text : String) return Boolean;
   --  Whether Text is a plain SQL numeric literal (optional sign, digits,
   --  optional fraction, optional exponent) — the only digit text safe to
   --  inline into a statement verbatim.

end Frostlake.Sql;
