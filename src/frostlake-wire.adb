pragma Ada_2022;

with Ada.Characters.Handling;

package body Frostlake.Wire is

   use Ada.Strings.Unbounded;

   function Upper (Text : String) return String
     renames Ada.Characters.Handling.To_Upper;

   function Lower (Text : String) return String
     renames Ada.Characters.Handling.To_Lower;

   Hex_Digit : constant array (0 .. 15) of Character := "0123456789ABCDEF";

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1)
                   = Prefix;
   end Starts_With;

   function Is_Digit (C : Character) return Boolean is
     (C in '0' .. '9');

   function Trimmed (Image : String) return String is
   begin
      if Image'Length > 0 and then Image (Image'First) = ' ' then
         return Image (Image'First + 1 .. Image'Last);
      end if;
      return Image;
   end Trimmed;

   ------------------------
   --  Numeric text      --
   ------------------------

   procedure To_Integer_If_Integral
     (Text  : String;
      Value : out Long_Long_Integer;
      Ok    : out Boolean)
   is
      Whole_Last : Natural := Text'Last;
      Seen_Digit : Boolean := False;
      Start      : Natural := Text'First;
   begin
      Value := 0;
      Ok := False;
      if Text'Length = 0 then
         return;
      end if;

      --  An exponent is never integral for our purposes; a fraction is
      --  only when it is all zeros.
      for I in Text'Range loop
         if Text (I) = 'e' or else Text (I) = 'E' then
            return;
         end if;
      end loop;
      for I in Text'Range loop
         if Text (I) = '.' then
            Whole_Last := I - 1;
            for J in I + 1 .. Text'Last loop
               if Text (J) /= '0' then
                  return;
               end if;
            end loop;
            exit;
         end if;
      end loop;

      if Text (Start) = '-' or else Text (Start) = '+' then
         Start := Start + 1;
      end if;
      if Start > Whole_Last then
         return;
      end if;
      for I in Start .. Whole_Last loop
         if not Is_Digit (Text (I)) then
            return;
         end if;
         Seen_Digit := True;
      end loop;
      if not Seen_Digit then
         return;
      end if;

      begin
         Value := Long_Long_Integer'Value (Text (Text'First .. Whole_Last));
         Ok := True;
      exception
         when Constraint_Error =>
            Value := 0;
            Ok := False;
      end;
   end To_Integer_If_Integral;

   function To_Long_Float (Number_Text : String) return Long_Float is
      Mantissa_Last : Natural := Number_Text'Last;
      Has_Point     : Boolean := False;
   begin
      for I in Number_Text'Range loop
         if Number_Text (I) = 'e' or else Number_Text (I) = 'E' then
            Mantissa_Last := I - 1;
            exit;
         end if;
         if Number_Text (I) = '.' then
            Has_Point := True;
         end if;
      end loop;
      if Has_Point then
         return Long_Float'Value (Number_Text);
      end if;
      return Long_Float'Value
        (Number_Text (Number_Text'First .. Mantissa_Last) & ".0"
         & Number_Text (Mantissa_Last + 1 .. Number_Text'Last));
   end To_Long_Float;

   ------------------------
   --  JSON escaping     --
   ------------------------

   function Escape_Json (Text : String) return String is
      Out_Text : Unbounded_String;
   begin
      for I in Text'Range loop
         declare
            C : constant Character := Text (I);
         begin
            case C is
               when '"' =>
                  Append (Out_Text, "\""");
               when '\' =>
                  Append (Out_Text, "\\");
               when Character'Val (8) =>
                  Append (Out_Text, "\b");
               when Character'Val (9) =>
                  Append (Out_Text, "\t");
               when Character'Val (10) =>
                  Append (Out_Text, "\n");
               when Character'Val (12) =>
                  Append (Out_Text, "\f");
               when Character'Val (13) =>
                  Append (Out_Text, "\r");
               when others =>
                  if Character'Pos (C) < 16#20# then
                     Append (Out_Text, "\u00");
                     Append (Out_Text, Hex_Digit (Character'Pos (C) / 16));
                     Append (Out_Text, Hex_Digit (Character'Pos (C) mod 16));
                  else
                     Append (Out_Text, C);
                  end if;
            end case;
         end;
      end loop;
      return To_String (Out_Text);
   end Escape_Json;

   -----------------------------
   --  Build_Execute_Request  --
   -----------------------------

   function Build_Execute_Request
     (Sql                   : String;
      Session_Id            : String;
      Auto_Commit           : Boolean;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count;
      Require_Session       : Boolean := False)
      return String
   is
      Out_Text : Unbounded_String;
   begin
      Append (Out_Text, "{""sql"":""");
      Append (Out_Text, Escape_Json (Sql));
      Append (Out_Text, """,""autoCommit"":");
      Append (Out_Text, (if Auto_Commit then "true" else "false"));
      if Session_Id'Length > 0 then
         Append (Out_Text, ",""sessionId"":""");
         Append (Out_Text, Escape_Json (Session_Id));
         Append (Out_Text, """");
         if Require_Session then
            Append (Out_Text, ",""requireSession"":true");
         end if;
      end if;
      if Multi_Statement_Count /= No_Multi_Statement_Count then
         Append (Out_Text, ",""multiStatementCount"":");
         Append (Out_Text, Trimmed (Integer'Image (Multi_Statement_Count)));
      end if;
      Append (Out_Text, "}");
      return To_String (Out_Text);
   end Build_Execute_Request;

   ------------------------
   --  Wire temporals    --
   ------------------------

   procedure Parse_Wire_Date
     (Text  : String;
      Value : out Date_Value;
      Ok    : out Boolean)
   is
      F : constant Natural := Text'First;

      function Two (At_Pos : Natural) return Integer is
        ((Character'Pos (Text (At_Pos)) - Character'Pos ('0')) * 10
         + (Character'Pos (Text (At_Pos + 1)) - Character'Pos ('0')));

   begin
      Value := (others => <>);
      Ok := False;
      if Text'Length /= 10
        or else Text (F + 4) /= '-' or else Text (F + 7) /= '-'
      then
         return;
      end if;
      for I in Text'Range loop
         if I /= F + 4 and then I /= F + 7 and then not Is_Digit (Text (I))
         then
            return;
         end if;
      end loop;
      declare
         Year : constant Integer := Two (F) * 100 + Two (F + 2);
      begin
         Value := (Year => Year, Month => Two (F + 5), Day => Two (F + 8));
         Ok := True;
      exception
         when Constraint_Error =>
            Value := (others => <>);
            Ok := False;
      end;
   end Parse_Wire_Date;

   procedure Parse_Wire_Timestamp
     (Text  : String;
      Value : out Timestamp_Value;
      Ok    : out Boolean)
   is
      F : constant Natural := Text'First;

      function Two (At_Pos : Natural) return Integer is
        ((Character'Pos (Text (At_Pos)) - Character'Pos ('0')) * 10
         + (Character'Pos (Text (At_Pos + 1)) - Character'Pos ('0')));

      Day_Part : Date_Value;
      Date_Ok  : Boolean;
      Pos      : Natural;
      Nanos    : Natural := 0;

      Has_Offset     : Boolean := False;
      Offset_Minutes : Integer := 0;
   begin
      Value := (others => <>);
      Ok := False;

      if Text'Length < 19 then
         return;
      end if;
      Parse_Wire_Date (Text (F .. F + 9), Day_Part, Date_Ok);
      if not Date_Ok then
         return;
      end if;
      if Text (F + 10) /= ' ' and then Text (F + 10) /= 'T' then
         return;
      end if;
      if Text (F + 13) /= ':' or else Text (F + 16) /= ':' then
         return;
      end if;
      for I in Natural'(F + 11) .. F + 18 loop
         if I /= F + 13 and then I /= F + 16 and then not Is_Digit (Text (I))
         then
            return;
         end if;
      end loop;

      Pos := F + 19;

      --  Fraction: one to nine digits; a tenth would not be the engine's.
      if Pos <= Text'Last and then Text (Pos) = '.' then
         declare
            Digit_Count : Natural := 0;
         begin
            Pos := Pos + 1;
            while Pos <= Text'Last and then Is_Digit (Text (Pos)) loop
               Digit_Count := Digit_Count + 1;
               if Digit_Count > 9 then
                  return;
               end if;
               Nanos := Nanos * 10
                 + (Character'Pos (Text (Pos)) - Character'Pos ('0'));
               Pos := Pos + 1;
            end loop;
            if Digit_Count = 0 then
               return;
            end if;
            for I in Digit_Count + 1 .. 9 loop
               Nanos := Nanos * 10;
            end loop;
         end;
      end if;

      --  Offset: absent, or "Z", or +/-HHMM, or +/-HH:MM — each after an
      --  optional single space.
      if Pos <= Text'Last and then Text (Pos) = ' ' then
         Pos := Pos + 1;
         if Pos > Text'Last then
            return;  --  a trailing space is not the engine's either
         end if;
      end if;
      if Pos <= Text'Last then
         if Text (Pos) = 'Z' then
            Has_Offset := True;
            Pos := Pos + 1;
         elsif Text (Pos) = '+' or else Text (Pos) = '-' then
            declare
               Negative : constant Boolean := Text (Pos) = '-';
               Hours    : Integer;
               Minutes  : Integer;
            begin
               Pos := Pos + 1;
               if Pos + 1 > Text'Last
                 or else not Is_Digit (Text (Pos))
                 or else not Is_Digit (Text (Pos + 1))
               then
                  return;
               end if;
               Hours := Two (Pos);
               Pos := Pos + 2;
               if Pos <= Text'Last and then Text (Pos) = ':' then
                  Pos := Pos + 1;
               end if;
               if Pos + 1 > Text'Last
                 or else not Is_Digit (Text (Pos))
                 or else not Is_Digit (Text (Pos + 1))
               then
                  return;
               end if;
               Minutes := Two (Pos);
               Pos := Pos + 2;
               Offset_Minutes := Hours * 60 + Minutes;
               if Negative then
                  Offset_Minutes := -Offset_Minutes;
               end if;
               Has_Offset := True;
            end;
         else
            return;
         end if;
      end if;
      if Pos <= Text'Last then
         return;  --  trailing junk
      end if;

      begin
         Value :=
           (Year           => Day_Part.Year,
            Month          => Day_Part.Month,
            Day            => Day_Part.Day,
            Hour           => Two (F + 11),
            Minute         => Two (F + 14),
            Second         => Two (F + 17),
            Nanosecond     => Nanos,
            Has_Offset     => Has_Offset,
            Offset_Minutes => Offset_Minutes);
         Ok := True;
      exception
         when Constraint_Error =>
            Value := (others => <>);
            Ok := False;
      end;
   end Parse_Wire_Timestamp;

   ------------------------
   --  Cell typing       --
   ------------------------

   function Is_Approximate (DT : String) return Boolean is
   begin
      return DT = "FLOAT" or else DT = "FLOAT4" or else DT = "FLOAT8"
        or else DT = "DOUBLE" or else DT = "DOUBLE PRECISION"
        or else DT = "REAL";
   end Is_Approximate;

   function Is_Timestamp_Type (DT : String) return Boolean is
   begin
      return DT = "TIMESTAMP" or else DT = "TIMESTAMP_NTZ"
        or else DT = "TIMESTAMP_LTZ" or else DT = "TIMESTAMP_TZ"
        or else DT = "DATETIME";
   end Is_Timestamp_Type;

   function Hex_Value (C : Character) return Natural is
   begin
      case C is
         when '0' .. '9' =>
            return Character'Pos (C) - Character'Pos ('0');
         when 'a' .. 'f' =>
            return Character'Pos (C) - Character'Pos ('a') + 10;
         when 'A' .. 'F' =>
            return Character'Pos (C) - Character'Pos ('A') + 10;
         when others =>
            return 16;
      end case;
   end Hex_Value;

   procedure Decode_Hex
     (Text  : String;
      Bytes : out Unbounded_String;
      Ok    : out Boolean)
   is
      I : Natural := Text'First;
   begin
      Bytes := Null_Unbounded_String;
      Ok := False;
      if Text'Length mod 2 /= 0 then
         return;
      end if;
      while I < Text'Last loop
         declare
            Hi : constant Natural := Hex_Value (Text (I));
            Lo : constant Natural := Hex_Value (Text (I + 1));
         begin
            if Hi > 15 or else Lo > 15 then
               Bytes := Null_Unbounded_String;
               return;
            end if;
            Append (Bytes, Character'Val (Hi * 16 + Lo));
         end;
         I := I + 2;
      end loop;
      Ok := True;
   end Decode_Hex;

   function Retype
     (Raw       : Cell;
      Data_Type : String;
      Scale     : Natural) return Cell
   is
      DT : constant String := Upper (Data_Type);
   begin
      if Raw.Kind = Null_Kind then
         return Raw;
      end if;

      --  FLOAT/DOUBLE/REAL are genuine binary floats; every other numeric
      --  the engine reports is fixed-point and keeps its digits.
      if Is_Approximate (DT) then
         case Raw.Kind is
            when Integer_Kind =>
               return (Kind => Float_Kind, Real => Long_Float (Raw.Int));
            when Decimal_Kind =>
               begin
                  return (Kind => Float_Kind,
                          Real => To_Long_Float (To_String (Raw.Exact)));
               exception
                  when Constraint_Error =>
                     return Raw;
               end;
            when others =>
               return Raw;
         end case;
      end if;

      if Raw.Kind = Text_Kind then
         declare
            Text : constant String := To_String (Raw.Text);
         begin
            if DT = "DATE" then
               declare
                  D  : Date_Value;
                  Ok : Boolean;
               begin
                  Parse_Wire_Date (Text, D, Ok);
                  if Ok then
                     return (Kind => Date_Kind, Date => D);
                  end if;
                  return Raw;
               end;
            elsif Is_Timestamp_Type (DT) then
               declare
                  T  : Timestamp_Value;
                  Ok : Boolean;
               begin
                  Parse_Wire_Timestamp (Text, T, Ok);
                  if Ok then
                     return (Kind => Timestamp_Kind, Stamp => T);
                  end if;
                  return Raw;
               end;
            elsif DT = "BINARY" or else DT = "VARBINARY" then
               declare
                  Bytes : Unbounded_String;
                  Ok    : Boolean;
               begin
                  --  The engine renders binary as hex.  Anything else is
                  --  not ours to reinterpret.
                  Decode_Hex (Text, Bytes, Ok);
                  if Ok then
                     return (Kind => Binary_Kind, Bytes => Bytes);
                  end if;
                  return Raw;
               end;
            elsif DT = "VARIANT" or else DT = "OBJECT" or else DT = "ARRAY"
            then
               return (Kind => Variant_Kind, Json => Raw.Text);
            end if;
            return Raw;
         end;
      end if;

      --  Scale 0 is an integer column; hand back an integer, but never
      --  truncate a value that unexpectedly carries a fraction.
      if Raw.Kind = Decimal_Kind and then Scale = 0 then
         declare
            V  : Long_Long_Integer;
            Ok : Boolean;
         begin
            To_Integer_If_Integral (To_String (Raw.Exact), V, Ok);
            if Ok then
               return (Kind => Integer_Kind, Int => V);
            end if;
         end;
      end if;

      return Raw;
   end Retype;

   ------------------------
   --  DML status rows   --
   ------------------------

   function Is_Dml_Status (Columns : Column_Vectors.Vector) return Boolean
   is
   begin
      if Columns.Is_Empty then
         return False;
      end if;
      for I in 1 .. Columns.Last_Index loop
         if not Starts_With
                  (Lower (To_String (Columns.Element (I).Name)),
                   "number of ")
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Dml_Status;

   function Dml_Row_Count
     (Columns : Column_Vectors.Vector;
      Row     : Cell_Vectors.Vector) return Natural
   is
      Total : Long_Long_Integer := 0;
   begin
      for I in 1 .. Columns.Last_Index loop
         if I <= Row.Last_Index
           and then Starts_With
                      (Lower (To_String (Columns.Element (I).Name)),
                       "number of rows ")
         then
            declare
               C : constant Cell := Row.Element (I);
            begin
               case C.Kind is
                  when Integer_Kind =>
                     Total := Total + C.Int;
                  when Decimal_Kind =>
                     declare
                        V  : Long_Long_Integer;
                        Ok : Boolean;
                     begin
                        To_Integer_If_Integral (To_String (C.Exact), V, Ok);
                        if Ok then
                           Total := Total + V;
                        end if;
                     end;
                  when others =>
                     null;
               end case;
            end;
         end if;
      end loop;
      if Total < 0 then
         return 0;
      end if;
      if Total > Long_Long_Integer (Natural'Last) then
         return Natural'Last;
      end if;
      return Natural (Total);
   end Dml_Row_Count;

   ------------------------
   --  Response parsing  --
   ------------------------

   function Parse_Response (Content : String) return Response is
      Pos : Natural := Content'First;
      Out_Response : Response;

      procedure Fail (Message : String) is
      begin
         raise Parse_Error with Message & " at offset"
           & Natural'Image (Pos - Content'First);
      end Fail;

      procedure Skip_Ws is
      begin
         while Pos <= Content'Last
           and then (Content (Pos) = ' '
                     or else Content (Pos) = Character'Val (9)
                     or else Content (Pos) = Character'Val (10)
                     or else Content (Pos) = Character'Val (13))
         loop
            Pos := Pos + 1;
         end loop;
      end Skip_Ws;

      function Peek return Character is
      begin
         if Pos > Content'Last then
            Fail ("unexpected end of response");
         end if;
         return Content (Pos);
      end Peek;

      procedure Expect (C : Character) is
      begin
         if Pos > Content'Last or else Content (Pos) /= C then
            Fail ("expected '" & C & "'");
         end if;
         Pos := Pos + 1;
      end Expect;

      procedure Expect_Word (Word : String) is
      begin
         if Pos + Word'Length - 1 > Content'Last
           or else Content (Pos .. Pos + Word'Length - 1) /= Word
         then
            Fail ("expected " & Word);
         end if;
         Pos := Pos + Word'Length;
      end Expect_Word;

      function Hex4 return Natural is
         V : Natural := 0;
      begin
         for I in 1 .. 4 loop
            declare
               H : constant Natural := Hex_Value (Peek);
            begin
               if H > 15 then
                  Fail ("bad \u escape");
               end if;
               V := V * 16 + H;
               Pos := Pos + 1;
            end;
         end loop;
         return V;
      end Hex4;

      procedure Append_Code_Point
        (Buffer : in out Unbounded_String;
         Code   : Natural) is
      begin
         if Code < 16#80# then
            Append (Buffer, Character'Val (Code));
         elsif Code < 16#800# then
            Append (Buffer, Character'Val (16#C0# + Code / 2**6));
            Append (Buffer, Character'Val (16#80# + Code mod 2**6));
         elsif Code < 16#1_0000# then
            Append (Buffer, Character'Val (16#E0# + Code / 2**12));
            Append (Buffer, Character'Val (16#80# + (Code / 2**6) mod 2**6));
            Append (Buffer, Character'Val (16#80# + Code mod 2**6));
         else
            Append (Buffer, Character'Val (16#F0# + Code / 2**18));
            Append (Buffer,
                    Character'Val (16#80# + (Code / 2**12) mod 2**6));
            Append (Buffer, Character'Val (16#80# + (Code / 2**6) mod 2**6));
            Append (Buffer, Character'Val (16#80# + Code mod 2**6));
         end if;
      end Append_Code_Point;

      function Parse_String_Value return Unbounded_String is
         Buffer : Unbounded_String;
      begin
         Expect ('"');
         loop
            if Pos > Content'Last then
               Fail ("unterminated string");
            end if;
            declare
               C : constant Character := Content (Pos);
            begin
               if C = '"' then
                  Pos := Pos + 1;
                  return Buffer;
               elsif C = '\' then
                  Pos := Pos + 1;
                  case Peek is
                     when '"' | '\' | '/' =>
                        Append (Buffer, Peek);
                        Pos := Pos + 1;
                     when 'b' =>
                        Append (Buffer, Character'Val (8));
                        Pos := Pos + 1;
                     when 'f' =>
                        Append (Buffer, Character'Val (12));
                        Pos := Pos + 1;
                     when 'n' =>
                        Append (Buffer, Character'Val (10));
                        Pos := Pos + 1;
                     when 'r' =>
                        Append (Buffer, Character'Val (13));
                        Pos := Pos + 1;
                     when 't' =>
                        Append (Buffer, Character'Val (9));
                        Pos := Pos + 1;
                     when 'u' =>
                        Pos := Pos + 1;
                        declare
                           Code : Natural := Hex4;
                        begin
                           --  A high surrogate pairs with the \uXXXX that
                           --  must follow it.
                           if Code in 16#D800# .. 16#DBFF#
                             and then Pos + 1 <= Content'Last
                             and then Content (Pos) = '\'
                             and then Content (Pos + 1) = 'u'
                           then
                              Pos := Pos + 2;
                              declare
                                 Low : constant Natural := Hex4;
                              begin
                                 if Low in 16#DC00# .. 16#DFFF# then
                                    Code := 16#1_0000#
                                      + (Code - 16#D800#) * 16#400#
                                      + (Low - 16#DC00#);
                                 else
                                    Append_Code_Point (Buffer, Code);
                                    Code := Low;
                                 end if;
                              end;
                           end if;
                           Append_Code_Point (Buffer, Code);
                        end;
                     when others =>
                        Fail ("bad escape");
                  end case;
               else
                  Append (Buffer, C);
                  Pos := Pos + 1;
               end if;
            end;
         end loop;
      end Parse_String_Value;

      function Parse_Number_Text return String is
         Start : constant Natural := Pos;
      begin
         if Peek = '-' then
            Pos := Pos + 1;
         end if;
         if not Is_Digit (Peek) then
            Fail ("expected a number");
         end if;
         while Pos <= Content'Last and then Is_Digit (Content (Pos)) loop
            Pos := Pos + 1;
         end loop;
         if Pos <= Content'Last and then Content (Pos) = '.' then
            Pos := Pos + 1;
            if not Is_Digit (Peek) then
               Fail ("expected fraction digits");
            end if;
            while Pos <= Content'Last and then Is_Digit (Content (Pos)) loop
               Pos := Pos + 1;
            end loop;
         end if;
         if Pos <= Content'Last
           and then (Content (Pos) = 'e' or else Content (Pos) = 'E')
         then
            Pos := Pos + 1;
            if Pos <= Content'Last
              and then (Content (Pos) = '+' or else Content (Pos) = '-')
            then
               Pos := Pos + 1;
            end if;
            if not Is_Digit (Peek) then
               Fail ("expected exponent digits");
            end if;
            while Pos <= Content'Last and then Is_Digit (Content (Pos)) loop
               Pos := Pos + 1;
            end loop;
         end if;
         return Content (Start .. Pos - 1);
      end Parse_Number_Text;

      --  Recursion mirrors the JSON nesting and every level consumes at
      --  least one character, so the depth is bounded by the response.
      pragma Warnings (Off, "possible infinite recursion*");
      pragma Warnings (Off, "*Storage_Error* may be raised*");

      procedure Skip_Value is
      begin
         Skip_Ws;
         case Peek is
            when '"' =>
               declare
                  Ignored : constant Unbounded_String := Parse_String_Value;
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            when '{' =>
               Pos := Pos + 1;
               Skip_Ws;
               if Peek = '}' then
                  Pos := Pos + 1;
                  return;
               end if;
               loop
                  Skip_Ws;
                  declare
                     Ignored : constant Unbounded_String :=
                       Parse_String_Value;
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
                  Skip_Ws;
                  Expect (':');
                  Skip_Value;
                  Skip_Ws;
                  if Peek = ',' then
                     Pos := Pos + 1;
                  else
                     Expect ('}');
                     return;
                  end if;
               end loop;
            when '[' =>
               Pos := Pos + 1;
               Skip_Ws;
               if Peek = ']' then
                  Pos := Pos + 1;
                  return;
               end if;
               loop
                  Skip_Value;
                  Skip_Ws;
                  if Peek = ',' then
                     Pos := Pos + 1;
                  else
                     Expect (']');
                     return;
                  end if;
               end loop;
            when 't' =>
               Expect_Word ("true");
            when 'f' =>
               Expect_Word ("false");
            when 'n' =>
               Expect_Word ("null");
            when others =>
               declare
                  Ignored : constant String := Parse_Number_Text;
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
         end case;
      end Skip_Value;

      pragma Warnings (On, "*Storage_Error* may be raised*");
      pragma Warnings (On, "possible infinite recursion*");

      function Parse_Raw_Cell return Cell is
      begin
         Skip_Ws;
         case Peek is
            when '"' =>
               return (Kind => Text_Kind, Text => Parse_String_Value);
            when 't' =>
               Expect_Word ("true");
               return (Kind => Boolean_Kind, Bool => True);
            when 'f' =>
               Expect_Word ("false");
               return (Kind => Boolean_Kind, Bool => False);
            when 'n' =>
               Expect_Word ("null");
               return (Kind => Null_Kind);
            when '{' | '[' =>
               --  A structured cell keeps its raw JSON text: the engine
               --  crosses VARIANT as text, so this is only ever a newer
               --  server's shape — hold it losslessly.
               declare
                  Start : constant Natural := Pos;
               begin
                  Skip_Value;
                  return (Kind => Variant_Kind,
                          Json => To_Unbounded_String
                                    (Content (Start .. Pos - 1)));
               end;
            when others =>
               declare
                  Number : constant String := Parse_Number_Text;
                  V      : Long_Long_Integer;
                  Is_Int : Boolean := Number'Length > 0;
               begin
                  for I in Number'Range loop
                     if not (Is_Digit (Number (I))
                             or else (I = Number'First
                                      and then Number (I) = '-'))
                     then
                        Is_Int := False;
                        exit;
                     end if;
                  end loop;
                  if Is_Int then
                     begin
                        V := Long_Long_Integer'Value (Number);
                        return (Kind => Integer_Kind, Int => V);
                     exception
                        when Constraint_Error =>
                           null;
                     end;
                  end if;
                  --  Keeps every JSON number exact: the engine serializes
                  --  fixed-point numerics with their digits, and a float
                  --  conversion here would round them away before the
                  --  column type is even known.
                  return (Kind => Decimal_Kind,
                          Exact => To_Unbounded_String (Number));
               end;
         end case;
      end Parse_Raw_Cell;

      procedure Parse_Column (Col : out Column_Info) is
      begin
         Col := (others => <>);
         Skip_Ws;
         Expect ('{');
         Skip_Ws;
         if Peek = '}' then
            Pos := Pos + 1;
            return;
         end if;
         loop
            Skip_Ws;
            declare
               Key : constant String := To_String (Parse_String_Value);
            begin
               Skip_Ws;
               Expect (':');
               Skip_Ws;
               if Key = "name" and then Peek = '"' then
                  Col.Name := Parse_String_Value;
               elsif Key = "dataType" and then Peek = '"' then
                  Col.Data_Type := Parse_String_Value;
               elsif Key = "precision" and then Peek /= 'n' then
                  declare
                     V  : Long_Long_Integer;
                     Ok : Boolean;
                  begin
                     To_Integer_If_Integral (Parse_Number_Text, V, Ok);
                     if Ok and then V in 0 .. Long_Long_Integer
                                            (Natural'Last)
                     then
                        Col.Precision := Natural (V);
                     end if;
                  end;
               elsif Key = "scale" and then Peek /= 'n' then
                  declare
                     V  : Long_Long_Integer;
                     Ok : Boolean;
                  begin
                     To_Integer_If_Integral (Parse_Number_Text, V, Ok);
                     if Ok and then V in 0 .. Long_Long_Integer
                                            (Natural'Last)
                     then
                        Col.Scale := Natural (V);
                     end if;
                  end;
               elsif Key = "length" and then Peek /= 'n' then
                  declare
                     V  : Long_Long_Integer;
                     Ok : Boolean;
                  begin
                     To_Integer_If_Integral (Parse_Number_Text, V, Ok);
                     if Ok and then V in 0 .. Long_Long_Integer
                                            (Natural'Last)
                     then
                        Col.Length := Natural (V);
                        Col.Has_Length := True;
                     end if;
                  end;
               elsif Key = "nullable" then
                  if Peek = 't' then
                     Expect_Word ("true");
                     Col.Can_Be_Null := Nullable;
                  elsif Peek = 'f' then
                     Expect_Word ("false");
                     Col.Can_Be_Null := Not_Nullable;
                  else
                     Skip_Value;
                  end if;
               else
                  Skip_Value;
               end if;
            end;
            Skip_Ws;
            if Peek = ',' then
               Pos := Pos + 1;
            else
               Expect ('}');
               return;
            end if;
         end loop;
      end Parse_Column;

      procedure Parse_Result_Set (Set : out Result) is
         Raw_Rows : Row_Vectors.Vector;
      begin
         Set := (others => <>);
         Skip_Ws;
         Expect ('{');
         Skip_Ws;
         if Peek = '}' then
            Pos := Pos + 1;
            return;
         end if;
         loop
            Skip_Ws;
            declare
               Key : constant String := To_String (Parse_String_Value);
            begin
               Skip_Ws;
               Expect (':');
               Skip_Ws;
               if Key = "columns" and then Peek = '[' then
                  Pos := Pos + 1;
                  Skip_Ws;
                  if Peek = ']' then
                     Pos := Pos + 1;
                  else
                     loop
                        declare
                           Col : Column_Info;
                        begin
                           Parse_Column (Col);
                           Set.Columns.Append (Col);
                        end;
                        Skip_Ws;
                        if Peek = ',' then
                           Pos := Pos + 1;
                        else
                           Expect (']');
                           exit;
                        end if;
                     end loop;
                  end if;
               elsif Key = "rows" and then Peek = '[' then
                  Pos := Pos + 1;
                  Skip_Ws;
                  if Peek = ']' then
                     Pos := Pos + 1;
                  else
                     loop
                        declare
                           Row : Cell_Vectors.Vector;
                        begin
                           Skip_Ws;
                           Expect ('[');
                           Skip_Ws;
                           if Peek = ']' then
                              Pos := Pos + 1;
                           else
                              loop
                                 Row.Append (Parse_Raw_Cell);
                                 Skip_Ws;
                                 if Peek = ',' then
                                    Pos := Pos + 1;
                                 else
                                    Expect (']');
                                    exit;
                                 end if;
                              end loop;
                           end if;
                           Raw_Rows.Append (Row);
                        end;
                        Skip_Ws;
                        if Peek = ',' then
                           Pos := Pos + 1;
                        else
                           Expect (']');
                           exit;
                        end if;
                     end loop;
                  end if;
               else
                  Skip_Value;
               end if;
            end;
            Skip_Ws;
            if Peek = ',' then
               Pos := Pos + 1;
            else
               Expect ('}');
               exit;
            end if;
         end loop;

         --  Cells are typed only now: the columns array may follow the
         --  rows in the object, so retyping mid-parse would race the
         --  metadata it needs.
         for R in 1 .. Raw_Rows.Last_Index loop
            declare
               Raw   : constant Cell_Vectors.Vector := Raw_Rows.Element (R);
               Typed : Cell_Vectors.Vector;
            begin
               for C in 1 .. Set.Columns.Last_Index loop
                  if C <= Raw.Last_Index then
                     Typed.Append
                       (Retype
                          (Raw.Element (C),
                           To_String (Set.Columns.Element (C).Data_Type),
                           Set.Columns.Element (C).Scale));
                  else
                     Typed.Append (Cell'(Kind => Null_Kind));
                  end if;
               end loop;
               Set.Rows.Append (Typed);
            end;
         end loop;
         Set.Row_Count := Natural (Set.Rows.Length);
      end Parse_Result_Set;

   begin
      Skip_Ws;
      Expect ('{');
      Skip_Ws;
      if Peek = '}' then
         Pos := Pos + 1;
         return Out_Response;
      end if;
      loop
         Skip_Ws;
         declare
            Key : constant String := To_String (Parse_String_Value);
         begin
            Skip_Ws;
            Expect (':');
            Skip_Ws;
            if Key = "success" then
               if Peek = 't' then
                  Expect_Word ("true");
                  Out_Response.Success := True;
               elsif Peek = 'f' then
                  Expect_Word ("false");
                  Out_Response.Success := False;
               else
                  Skip_Value;
               end if;
            elsif Key = "sessionId" then
               if Peek = '"' then
                  Out_Response.Session_Id := Parse_String_Value;
                  Out_Response.Has_Session_Id := True;
               else
                  Skip_Value;
               end if;
            elsif Key = "newSession" then
               if Peek = 't' then
                  Expect_Word ("true");
                  Out_Response.New_Session := True;
                  Out_Response.Has_New_Session := True;
               elsif Peek = 'f' then
                  Expect_Word ("false");
                  Out_Response.New_Session := False;
                  Out_Response.Has_New_Session := True;
               else
                  Skip_Value;
               end if;
            elsif Key = "errorMessage" then
               if Peek = '"' then
                  Out_Response.Error_Message := Parse_String_Value;
                  Out_Response.Has_Error_Message := True;
               else
                  Skip_Value;
               end if;
            elsif Key = "resultSets" and then Peek = '[' then
               Pos := Pos + 1;
               Skip_Ws;
               if Peek = ']' then
                  Pos := Pos + 1;
               else
                  loop
                     declare
                        Set : Result;
                     begin
                        Parse_Result_Set (Set);
                        Out_Response.Result_Sets.Append (Set);
                     end;
                     Skip_Ws;
                     if Peek = ',' then
                        Pos := Pos + 1;
                     else
                        Expect (']');
                        exit;
                     end if;
                  end loop;
               end if;
            else
               Skip_Value;
            end if;
         end;
         Skip_Ws;
         if Peek = ',' then
            Pos := Pos + 1;
         else
            Expect ('}');
            exit;
         end if;
      end loop;
      return Out_Response;
   end Parse_Response;

end Frostlake.Wire;
