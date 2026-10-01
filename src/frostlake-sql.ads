pragma Ada_2022;

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

   function Touches_Session (Sql : String) return Boolean;
   --  Whether any statement of the request leaves behind state a fresh
   --  session would not have: a moved scope (USE, or CREATE/DROP of a
   --  DATABASE or SCHEMA), a session variable or setting (SET, UNSET, ALTER
   --  SESSION), or a temporary object.  CREATE TABLE and its kind leave the
   --  session as it was.  Statements are split on the semicolons outside
   --  literals, quoted identifiers, $$...$$ bodies and comments; a
   --  scripting block is split along with everything else, which only makes
   --  the check more willing to say yes -- the safe direction.

   type Transaction_Change is (No_Change, Opens, Closes);

   function Transaction_Effect (Sql : String) return Transaction_Change;
   --  What the request leaves the session's transaction as: the effect of
   --  its last statement that opens one (BEGIN on its own or with
   --  TRANSACTION, WORK or NAME; START TRANSACTION) or ends one (COMMIT,
   --  ROLLBACK).  BEGIN followed by a statement opens a scripting block
   --  instead, which is No_Change.

   function Is_Numeric_Literal (Text : String) return Boolean;
   --  Whether Text is a plain SQL numeric literal (optional sign, digits,
   --  optional fraction, optional exponent) — the only digit text safe to
   --  inline into a statement verbatim.

end Frostlake.Sql;
