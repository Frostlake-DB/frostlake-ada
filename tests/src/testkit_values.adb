with Ada.Long_Float_Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Wide_Wide_Characters.Handling;

with Testkit_Json;

package body Testkit_Values is

   use Ada.Strings.Unbounded;

   function To_Text_Cell (Text : String) return Text_Cell is
     ((Present => True, Text => To_Unbounded_String (Text)));

   function Image (Cell : Text_Cell) return String is
     (if Cell.Present then To_String (Cell.Text) else "null");

   --  ASCII only: a Latin-1 fold would rewrite the bytes of UTF-8 text.
   function Ascii_Lower (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return Result;
   end Ascii_Lower;

   function Ascii_Upper (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C in 'a' .. 'z' then
            C := Character'Val (Character'Pos (C) - 32);
         end if;
      end loop;
      return Result;
   end Ascii_Upper;

   --  Java's String.trim: every character up to and including the space.
   function Java_Trim (Text : String) return String is
      First : Positive := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) <= ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) <= ' ' loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Java_Trim;

   ------------------------
   --  Decimal numbers   --
   ------------------------

   --  A number as BigDecimal reads it: the value is the integer Figures
   --  (every digit written, the point dropped) times ten to Exponent.
   type Decimal is record
      Negative : Boolean := False;
      Figures  : Unbounded_String;
      Exponent : Long_Long_Integer := 0;
   end record;

   --  Past this many zeros a number is not worth printing out plainly; it
   --  then compares as the text it is.
   Max_Plain_Exponent : constant := 100_000;

   --  BigDecimal's grammar: an optional sign, digits with at most one point
   --  (and at least one digit), then an optional exponent that fits an int.
   procedure Read_Decimal
     (Text  : String;
      Value : out Decimal;
      Ok    : out Boolean)
   is
      Pos        : Natural := Text'First;
      Fraction   : Long_Long_Integer := 0;
      Seen_Point : Boolean := False;
      Exponent   : Long_Long_Integer := 0;
   begin
      Value := (others => <>);
      Ok := False;
      if Pos <= Text'Last and then (Text (Pos) = '+' or else Text (Pos) = '-')
      then
         Value.Negative := Text (Pos) = '-';
         Pos := Pos + 1;
      end if;
      while Pos <= Text'Last loop
         if Text (Pos) in '0' .. '9' then
            Append (Value.Figures, Text (Pos));
            if Seen_Point then
               Fraction := Fraction + 1;
            end if;
         elsif Text (Pos) = '.' and then not Seen_Point then
            Seen_Point := True;
         else
            exit;
         end if;
         Pos := Pos + 1;
      end loop;
      if Length (Value.Figures) = 0 then
         return;
      end if;
      if Pos <= Text'Last then
         if Text (Pos) /= 'e' and then Text (Pos) /= 'E' then
            return;
         end if;
         Pos := Pos + 1;
         declare
            Negative_Exponent : Boolean := False;
            Exponent_Digits   : Natural := 0;
         begin
            if Pos <= Text'Last
              and then (Text (Pos) = '+' or else Text (Pos) = '-')
            then
               Negative_Exponent := Text (Pos) = '-';
               Pos := Pos + 1;
            end if;
            while Pos <= Text'Last and then Text (Pos) in '0' .. '9' loop
               Exponent_Digits := Exponent_Digits + 1;
               if Exponent_Digits > 10 then
                  return;
               end if;
               Exponent := Exponent * 10
                 + Long_Long_Integer
                     (Character'Pos (Text (Pos)) - Character'Pos ('0'));
               Pos := Pos + 1;
            end loop;
            if Exponent_Digits = 0 or else Pos <= Text'Last
              or else Exponent > Long_Long_Integer (Integer'Last)
            then
               return;
            end if;
            if Negative_Exponent then
               Exponent := -Exponent;
            end if;
         end;
      end if;
      Value.Exponent := Exponent - Fraction;
      Ok := True;
   end Read_Decimal;

   function Without_Leading_Zeros (Figures : String) return String is
      First : Positive := Figures'First;
   begin
      while First <= Figures'Last and then Figures (First) = '0' loop
         First := First + 1;
      end loop;
      return Figures (First .. Figures'Last);
   end Without_Leading_Zeros;

   --  Figures times ten to Exponent, written out with no exponent.
   function Plain_Text
     (Negative : Boolean;
      Figures  : String;
      Exponent : Long_Long_Integer) return String
   is
      Sign : constant String := (if Negative then "-" else "");
   begin
      if Exponent >= 0 then
         return Sign & Figures & [1 .. Natural (Exponent) => '0'];
      end if;
      declare
         Point : constant Long_Long_Integer :=
           Long_Long_Integer (Figures'Length) + Exponent;
      begin
         if Point > 0 then
            declare
               Cut : constant Positive := Figures'First + Natural (Point);
            begin
               return Sign & Figures (Figures'First .. Cut - 1) & '.'
                 & Figures (Cut .. Figures'Last);
            end;
         end if;
         return Sign & "0." & [1 .. Natural (-Point) => '0'] & Figures;
      end;
   end Plain_Text;

   function Plain_Number (Text : String) return String is
      Number : Decimal;
      Ok     : Boolean;
   begin
      Read_Decimal (Text, Number, Ok);
      if not Ok or else abs Number.Exponent > Max_Plain_Exponent then
         return Text;
      end if;
      declare
         Figures : constant String :=
           Without_Leading_Zeros (To_String (Number.Figures));
      begin
         if Figures'Length = 0 then
            --  BigDecimal has no negative zero, and a zero keeps only the
            --  places after its point.
            return Plain_Text (False, "0", Long_Long_Integer'Min
                                             (Number.Exponent, 0));
         end if;
         return Plain_Text (Number.Negative, Figures, Number.Exponent);
      end;
   end Plain_Number;

   --  Moves Figures' trailing zeros into Exponent: 1500 x 10^0 becomes
   --  15 x 10^2.
   procedure Strip_Trailing_Zeros
     (Figures  : in out Unbounded_String;
      Exponent : in out Long_Long_Integer) is
   begin
      while Length (Figures) > 1
        and then Element (Figures, Length (Figures)) = '0'
      loop
         Delete (Figures, Length (Figures), Length (Figures));
         Exponent := Exponent + 1;
      end loop;
   end Strip_Trailing_Zeros;

   --  Ten significant digits, half up, then no trailing zeros:
   --  BigDecimal.round (new MathContext (10)).stripTrailingZeros ().
   function Rounded (Number : Decimal) return String is
      Figures  : Unbounded_String :=
        To_Unbounded_String
          (Without_Leading_Zeros (To_String (Number.Figures)));
      Exponent : Long_Long_Integer := Number.Exponent;
   begin
      if Length (Figures) = 0 then
         return "0";
      end if;
      if Length (Figures) > 10 then
         declare
            Dropped : constant Character := Element (Figures, 11);
            Kept    : String (1 .. 10) := Slice (Figures, 1, 10);
            Carry   : Boolean := Dropped >= '5';
         begin
            Exponent := Exponent + Long_Long_Integer (Length (Figures) - 10);
            for I in reverse Kept'Range loop
               exit when not Carry;
               if Kept (I) = '9' then
                  Kept (I) := '0';
               else
                  Kept (I) := Character'Succ (Kept (I));
                  Carry := False;
               end if;
            end loop;
            if Carry then
               --  9999999999 went up to 10000000000: one digit more.
               Kept := [1 => '1', others => '0'];
               Exponent := Exponent + 1;
            end if;
            Figures := To_Unbounded_String (Kept);
         end;
      end if;
      Strip_Trailing_Zeros (Figures, Exponent);
      return Plain_Text (Number.Negative, To_String (Figures), Exponent);
   end Rounded;

   function Norm (Cell : Text_Cell) return String is
   begin
      if not Cell.Present then
         return "NULL";
      end if;
      declare
         Value  : constant String := Java_Trim (To_String (Cell.Text));
         Folded : constant String := Ascii_Lower (Value);
         Number : Decimal;
         Ok     : Boolean;
      begin
         if Value'Length = 0 or else Folded = "null" then
            return "NULL";
         elsif Folded = "true" then
            return "TRUE";
         elsif Folded = "false" then
            return "FALSE";
         end if;
         Read_Decimal (Value, Number, Ok);
         if not Ok or else abs Number.Exponent > Max_Plain_Exponent then
            return Value;
         end if;
         return Rounded (Number);
      end;
   end Norm;

   ------------------------
   --  Driver cells      --
   ------------------------

   function Float_Text (Value : Long_Float) return String is

      --  Value in scientific notation, with Aft + 1 significant digits.
      function Written (Aft : Positive) return String is
         Buffer : String (1 .. 40);
      begin
         Ada.Long_Float_Text_IO.Put
           (To => Buffer, Item => Value, Aft => Aft, Exp => 1);
         return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
      end Written;

      --  Two significant digits and up, until the text reads back as the
      --  very same double; seventeen always do.
      function Shortest return String is
      begin
         for Aft in 1 .. 15 loop
            if Long_Float'Value (Written (Aft)) = Value then
               return Written (Aft);
            end if;
         end loop;
         return Written (16);
      end Shortest;

   begin
      if Value = 0.0 then
         return "0.0";
      end if;
      declare
         Text     : constant String := Shortest;
         Number   : Decimal;
         Ok       : Boolean;
         Figures  : Unbounded_String;
         Exponent : Long_Long_Integer;
      begin
         Read_Decimal (Text, Number, Ok);
         if not Ok then
            return Text;
         end if;
         Figures := To_Unbounded_String
           (Without_Leading_Zeros (To_String (Number.Figures)));
         Exponent := Number.Exponent;
         Strip_Trailing_Zeros (Figures, Exponent);
         return Plain_Text (Number.Negative, To_String (Figures), Exponent);
      end;
   end Float_Text;

   function Timestamp_Text (Value : Frostlake.Timestamp_Value) return String
   is
      --  "YYYY-MM-DD HH:MM:SS.NNNNNNNNN", then " +HHMM" when zoned.
      Full  : constant String := Frostlake.Image (Value);
      Point : constant Positive := Full'First + 19;
      Kept  : constant Positive :=
        (if Value.Nanosecond mod 1_000_000 = 0 then 3
         elsif Value.Nanosecond mod 1_000 = 0 then 6
         else 9);
   begin
      return Full (Full'First .. Point + Kept)
        & Full (Point + 10 .. Full'Last);
   end Timestamp_Text;

   function Cell_Text (Value : Frostlake.Cell) return Text_Cell is
      use Frostlake;
   begin
      case Value.Kind is
         when Null_Kind =>
            return Null_Text;
         when Boolean_Kind =>
            return To_Text_Cell
              ((if As_Boolean (Value) then "true" else "false"));
         when Integer_Kind =>
            return To_Text_Cell
              (Ada.Strings.Fixed.Trim
                 (Long_Long_Integer'Image (As_Integer (Value)),
                  Ada.Strings.Left));
         when Decimal_Kind | Text_Kind | Variant_Kind =>
            return To_Text_Cell (As_String (Value));
         when Float_Kind =>
            return To_Text_Cell (Float_Text (As_Float (Value)));
         when Date_Kind =>
            return To_Text_Cell (Image (As_Date (Value)));
         when Timestamp_Kind =>
            return To_Text_Cell (Timestamp_Text (As_Timestamp (Value)));
         when Binary_Kind =>
            --  The driver's image of a BINARY cell is its uppercase hex.
            return To_Text_Cell (Image (Value));
      end case;
   end Cell_Text;

   function Is_Semi_Structured (Type_Name : String) return Boolean is
      Upper : constant String := Ascii_Upper (Type_Name);
   begin
      return Upper = "VARIANT" or else Upper = "OBJECT"
        or else Upper = "ARRAY";
   end Is_Semi_Structured;

   function Semi_Structured_Value (Cell : Text_Cell) return Text_Cell is
      use type Testkit_Json.Value_Kind;
   begin
      if not Cell.Present then
         return Cell;
      end if;
      declare
         Doc : constant Testkit_Json.Document :=
           Testkit_Json.Parse (To_String (Cell.Text));
         Top : constant Testkit_Json.Node := Testkit_Json.Root (Doc);
      begin
         if Testkit_Json.Kind (Doc, Top) = Testkit_Json.String_Value then
            return To_Text_Cell (Testkit_Json.Text (Doc, Top));
         end if;
         return Cell;
      end;
   exception
      when Testkit_Json.Parse_Error =>
         --  Text that is not JSON at all is a value in its own right.
         return Cell;
   end Semi_Structured_Value;

   ------------------------
   --  Case folding      --
   ------------------------

   function Lower (Text : String) return String is
      use Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   begin
      return Encode (Ada.Wide_Wide_Characters.Handling.To_Lower
                       (Decode (Text)));
   exception
      when Ada.Strings.UTF_Encoding.Encoding_Error =>
         return Ascii_Lower (Text);
   end Lower;

   function Equal_Ignoring_Case (Left : String; Right : String)
      return Boolean
   is
      use Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
      use Ada.Wide_Wide_Characters.Handling;
   begin
      declare
         L : constant Wide_Wide_String := Decode (Left);
         R : constant Wide_Wide_String := Decode (Right);
      begin
         if L'Length /= R'Length then
            return False;
         end if;
         for I in 0 .. L'Length - 1 loop
            declare
               A : constant Wide_Wide_Character := L (L'First + I);
               B : constant Wide_Wide_Character := R (R'First + I);
            begin
               if A /= B
                 and then To_Upper (A) /= To_Upper (B)
                 and then To_Lower (To_Upper (A)) /= To_Lower (To_Upper (B))
               then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end;
   exception
      when Ada.Strings.UTF_Encoding.Encoding_Error =>
         return Ascii_Lower (Left) = Ascii_Lower (Right);
   end Equal_Ignoring_Case;

   function Contains_Ignoring_Case (Text : String; Fragment : String)
      return Boolean is
   begin
      if Fragment'Length = 0 then
         return True;
      end if;
      return Ada.Strings.Fixed.Index (Lower (Text), Lower (Fragment)) > 0;
   end Contains_Ignoring_Case;

end Testkit_Values;
