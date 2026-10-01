--  How the testkit corpus runner reads values: the corpus's normalization,
--  a driver cell as the text the wire carried, and the case-insensitive
--  matching the checks use.  A port of the Java reference runner's Compare
--  and SemiStructuredCells (engine/src/test/java/dev/frostlake/testkit).

with Ada.Strings.Unbounded;

with Frostlake;

package Testkit_Values is

   --  A value as text, or SQL NULL.
   type Text_Cell is record
      Present : Boolean := False;
      Text    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   Null_Text : constant Text_Cell :=
     (Present => False, Text => Ada.Strings.Unbounded.Null_Unbounded_String);

   function To_Text_Cell (Text : String) return Text_Cell;

   function Image (Cell : Text_Cell) return String;
   --  The text, or "null" for NULL — for messages.

   function Norm (Cell : Text_Cell) return String;
   --  The corpus's value normalization, applied to both sides before they
   --  compare: NULL, the empty string and "null" read as NULL; booleans
   --  fold case; anything Java's BigDecimal reads as a number compares as
   --  that number rounded to 10 significant digits, half up, printed plain
   --  with no trailing zeros; everything else is the trimmed text.

   function Plain_Number (Text : String) return String;
   --  A number's text as BigDecimal.toPlainString prints it ("1E+3" is
   --  "1000", "1.50" stays "1.50"); anything that is not a number comes
   --  back unchanged.

   function Cell_Text (Value : Frostlake.Cell) return Text_Cell;
   --  A driver cell as the text the wire carried for it, which is what the
   --  corpus records.  The driver hands most values over exactly — digits,
   --  text, JSON — and the rest are rendered back in the engine's own
   --  transport form: a FLOAT as the shortest decimal that reads back to
   --  the same double, a DATE as YYYY-MM-DD, a TIMESTAMP with three, six
   --  or nine fractional digits (as many as its value needs) and a zoned
   --  one's +HHMM offset, BINARY as uppercase hex.

   function Float_Text (Value : Long_Float) return String;
   --  The shortest plain decimal that reads back to Value.

   function Timestamp_Text (Value : Frostlake.Timestamp_Value) return String;
   --  "YYYY-MM-DD HH:MM:SS.fff" — three, six or nine fractional digits —
   --  plus " +HHMM" when the value carries an offset.

   function Is_Semi_Structured (Type_Name : String) return Boolean;
   --  VARIANT, OBJECT or ARRAY, in any case.

   function Semi_Structured_Value (Cell : Text_Cell) return Text_Cell;
   --  A semi-structured cell reaches a client as its JSON text, a string's
   --  own quotes included; the corpus records the value.  One level of
   --  decoding: a cell that is a JSON string becomes that string's content,
   --  and any other cell — a number, a boolean, an object, text that is not
   --  JSON at all — is left exactly as it came.

   function Lower (Text : String) return String;
   --  UTF-8 text in lower case (bytes that are not UTF-8 fold as ASCII).

   function Equal_Ignoring_Case (Left : String; Right : String)
      return Boolean;
   --  Java's String.equalsIgnoreCase, over UTF-8 text.

   function Contains_Ignoring_Case (Text : String; Fragment : String)
      return Boolean;
   --  Whether Fragment occurs in Text, both lower-cased; an empty Fragment
   --  always does.

end Testkit_Values;
