pragma Ada_2022;

with Ada.Strings.Unbounded;

package body Frostlake.Sql is

   use Ada.Strings.Unbounded;

   ------------------------
   --  Small formatting  --
   ------------------------

   function Trimmed (Image : String) return String is
   begin
      if Image'Length > 0 and then Image (Image'First) = ' ' then
         return Image (Image'First + 1 .. Image'Last);
      end if;
      return Image;
   end Trimmed;

   function Padded (Value : Natural; Width : Positive) return String is
      Raw    : constant String := Trimmed (Natural'Image (Value));
      Result : String (1 .. Width) := (others => '0');
   begin
      if Raw'Length >= Width then
         return Raw;
      end if;
      Result (Width - Raw'Length + 1 .. Width) := Raw;
      return Result;
   end Padded;

   function Is_Space (C : Character) return Boolean is
   begin
      --  Ruby's \s: space, tab, newline, carriage return, form feed,
      --  vertical tab.
      return C = ' ' or else C = Character'Val (9)
        or else C = Character'Val (10) or else C = Character'Val (11)
        or else C = Character'Val (12) or else C = Character'Val (13);
   end Is_Space;

   function Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val
           (Character'Pos (C) - Character'Pos ('a') + Character'Pos ('A'));
      end if;
      return C;
   end Upper;

   --  A plain SQL numeric literal: the only digit text safe to inline
   --  verbatim.  Anything else in a Decimal cell would splice raw text
   --  into the statement.
   function Is_Numeric_Literal (Text : String) return Boolean is
      I : Natural := Text'First;

      function More return Boolean is (I <= Text'Last);

      function Digits_Run return Boolean is
         Seen : Boolean := False;
      begin
         while More and then Text (I) in '0' .. '9' loop
            Seen := True;
            I := I + 1;
         end loop;
         return Seen;
      end Digits_Run;

   begin
      if Text'Length = 0 then
         return False;
      end if;
      if Text (I) = '+' or else Text (I) = '-' then
         I := I + 1;
      end if;
      if not Digits_Run then
         return False;
      end if;
      if More and then Text (I) = '.' then
         I := I + 1;
         if not Digits_Run then
            return False;
         end if;
      end if;
      if More and then (Text (I) = 'e' or else Text (I) = 'E') then
         I := I + 1;
         if More and then (Text (I) = '+' or else Text (I) = '-') then
            I := I + 1;
         end if;
         if not Digits_Run then
            return False;
         end if;
      end if;
      return not More;
   end Is_Numeric_Literal;

   ----------------------
   --  Quote_Identifier --
   ----------------------

   function Quote_Identifier (Name : String) return String is
      Out_Text : Unbounded_String;
   begin
      if Name'Length = 0 then
         raise Usage_Error with "identifier cannot be empty";
      end if;
      Append (Out_Text, '"');
      for I in Name'Range loop
         if Name (I) = '"' then
            Append (Out_Text, """""");
         else
            Append (Out_Text, Name (I));
         end if;
      end loop;
      Append (Out_Text, '"');
      return To_String (Out_Text);
   end Quote_Identifier;

   ---------------------
   --  Format_Literal --
   ---------------------

   function Encoded_Text (Text : String) return String is
      Out_Text : Unbounded_String;
   begin
      Append (Out_Text, ''');
      for I in Text'Range loop
         if Text (I) = '\' then
            Append (Out_Text, "\\");
         elsif Text (I) = ''' then
            Append (Out_Text, "''");
         else
            Append (Out_Text, Text (I));
         end if;
      end loop;
      Append (Out_Text, ''');
      return To_String (Out_Text);
   end Encoded_Text;

   Hex_Digit : constant array (0 .. 15) of Character := "0123456789ABCDEF";

   function Hex_Of (Bytes : String) return String is
      Out_Text : String (1 .. Bytes'Length * 2);
      J        : Natural := 0;
   begin
      for I in Bytes'Range loop
         J := J + 2;
         Out_Text (J - 1) := Hex_Digit (Character'Pos (Bytes (I)) / 16);
         Out_Text (J) := Hex_Digit (Character'Pos (Bytes (I)) mod 16);
      end loop;
      return Out_Text;
   end Hex_Of;

   function Offset_Image (Offset_Minutes : Integer) return String is
      Total : constant Natural := abs Offset_Minutes;
      Sign  : constant Character :=
        (if Offset_Minutes < 0 then '-' else '+');
   begin
      return Sign & Padded (Total / 60, 2) & ':' & Padded (Total mod 60, 2);
   end Offset_Image;

   function Format_Literal (Value : Cell) return String is
   begin
      case Value.Kind is
         when Null_Kind =>
            return "NULL";

         when Boolean_Kind =>
            return (if Value.Bool then "TRUE" else "FALSE");

         when Integer_Kind =>
            return Trimmed (Long_Long_Integer'Image (Value.Int));

         when Decimal_Kind =>
            declare
               Text : constant String := To_String (Value.Exact);
            begin
               if not Is_Numeric_Literal (Text) then
                  raise Usage_Error with
                    "decimal bind is not a numeric literal: " & Text;
               end if;
               return Text;
            end;

         when Float_Kind =>
            if Value.Real /= Value.Real
              or else Value.Real > Long_Float'Last
              or else Value.Real < Long_Float'First
            then
               raise Usage_Error with "non-finite number cannot be bound";
            end if;
            return Trimmed (Long_Float'Image (Value.Real));

         when Text_Kind =>
            return Encoded_Text (To_String (Value.Text));

         when Date_Kind =>
            return ''' & Padded (Value.Date.Year, 4) & '-'
              & Padded (Value.Date.Month, 2) & '-'
              & Padded (Value.Date.Day, 2) & "'::DATE";

         when Timestamp_Kind =>
            declare
               T    : constant Timestamp_Value := Value.Stamp;
               Core : constant String :=
                 Padded (T.Year, 4) & '-' & Padded (T.Month, 2) & '-'
                 & Padded (T.Day, 2)
                 & (if T.Has_Offset then "T" else " ")
                 & Padded (T.Hour, 2) & ':' & Padded (T.Minute, 2) & ':'
                 & Padded (T.Second, 2) & '.' & Padded (T.Nanosecond, 9);
            begin
               --  A timestamp carrying an offset maps to TIMESTAMP_TZ;
               --  casting it to NTZ would silently discard that offset.
               if T.Has_Offset then
                  return ''' & Core & Offset_Image (T.Offset_Minutes)
                    & "'::TIMESTAMP_TZ";
               end if;
               return ''' & Core & "'::TIMESTAMP_NTZ";
            end;

         when Binary_Kind =>
            return "X'" & Hex_Of (To_String (Value.Bytes)) & ''';

         when Variant_Kind =>
            return "PARSE_JSON(" & Encoded_Text (To_String (Value.Json))
              & ')';
      end case;
   end Format_Literal;

   ------------------
   --  Substitute  --
   ------------------

   function Substitute (Sql : String; Binds : Bind_Array) return String is
      Out_Text : Unbounded_String;
      I        : Natural := Sql'First;
      Next     : Natural := Binds'First;

      procedure Copy_Through (Last : Natural) is
      begin
         Append (Out_Text, Sql (I .. Last));
         I := Last + 1;
      end Copy_Through;

      --  Past the closing quote of a '...' literal.  A backslash always
      --  escapes; '' is a doubled quote.
      function String_End return Natural is
         J : Natural := I + 1;
      begin
         while J <= Sql'Last loop
            if Sql (J) = '\' then
               J := J + 2;
            elsif Sql (J) = ''' then
               if J < Sql'Last and then Sql (J + 1) = ''' then
                  J := J + 2;
               else
                  return J;
               end if;
            else
               J := J + 1;
            end if;
         end loop;
         return Sql'Last;
      end String_End;

      --  Past the closing quote of a "..." identifier ("" is doubled).
      function Quoted_End return Natural is
         J : Natural := I + 1;
      begin
         while J <= Sql'Last loop
            if Sql (J) = '"' then
               if J < Sql'Last and then Sql (J + 1) = '"' then
                  J := J + 2;
               else
                  return J;
               end if;
            else
               J := J + 1;
            end if;
         end loop;
         return Sql'Last;
      end Quoted_End;

      --  Through the end of the line, newline included.
      function Line_End return Natural is
      begin
         for J in I .. Sql'Last loop
            if Sql (J) = Character'Val (10) then
               return J;
            end if;
         end loop;
         return Sql'Last;
      end Line_End;

      --  Past a closing Mark (*/ or $$); to the end when unterminated.
      function Pair_End (Mark : String) return Natural is
      begin
         for J in I + 2 .. Sql'Last - 1 loop
            if Sql (J .. J + 1) = Mark then
               return J + 1;
            end if;
         end loop;
         return Sql'Last;
      end Pair_End;

   begin
      while I <= Sql'Last loop
         if Sql (I) = ''' then
            Copy_Through (Natural'Min (String_End, Sql'Last));
         elsif Sql (I) = '"' then
            Copy_Through (Quoted_End);
         elsif Sql (I) = '-' and then I < Sql'Last
           and then Sql (I + 1) = '-'
         then
            Copy_Through (Line_End);
         elsif Sql (I) = '/' and then I < Sql'Last
           and then Sql (I + 1) = '*'
         then
            Copy_Through (Pair_End ("*/"));
         elsif Sql (I) = '/' and then I < Sql'Last
           and then Sql (I + 1) = '/'
         then
            Copy_Through (Line_End);
         elsif Sql (I) = '$' and then I < Sql'Last
           and then Sql (I + 1) = '$'
         then
            --  UDF and procedure bodies are written as $$...$$, so a ?
            --  inside one is part of the body, not a placeholder.
            Copy_Through (Pair_End ("$$"));
         elsif Sql (I) = '?' then
            if Next > Binds'Last then
               raise Usage_Error with
                 "not enough bind values for placeholders";
            end if;
            Append (Out_Text, Format_Literal (Binds (Next)));
            Next := Next + 1;
            I := I + 1;
         else
            Append (Out_Text, Sql (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Out_Text);
   end Substitute;

   ---------------------------------
   --  Selects_Session_State      --
   ---------------------------------

   function Selects_Session_State (Sql : String) return Boolean is

      function Use_At (Start : Natural) return Boolean is
         J : Natural := Start;
      begin
         while J <= Sql'Last and then Is_Space (Sql (J)) loop
            J := J + 1;
         end loop;
         return J + 3 <= Sql'Last
           and then Upper (Sql (J)) = 'U'
           and then Upper (Sql (J + 1)) = 'S'
           and then Upper (Sql (J + 2)) = 'E'
           and then Is_Space (Sql (J + 3));
      end Use_At;

   begin
      if Use_At (Sql'First) then
         return True;
      end if;
      for I in Sql'First .. Sql'Last loop
         if (Sql (I) = ';' or else Sql (I) = Character'Val (10))
           and then Use_At (I + 1)
         then
            return True;
         end if;
      end loop;
      return False;
   end Selects_Session_State;

   ------------------------------------------
   --  Touches_Session, Transaction_Effect --
   ------------------------------------------

   --  Just past the literal, quoted identifier, $$ body or comment opening
   --  at I, or 0 when I is code: the rules Substitute follows, so binding and
   --  session tracking cannot disagree about what is code.
   function Skip_Non_Code (Sql : String; I : Positive) return Natural is
      Next : constant Character :=
        (if I < Sql'Last then Sql (I + 1) else Character'Val (0));
      J    : Natural;

      function Line_End return Natural is
      begin
         for K in I .. Sql'Last loop
            if Sql (K) = Character'Val (10) then
               return K + 1;
            end if;
         end loop;
         return Sql'Last + 1;
      end Line_End;

      function Pair_End (Mark : String) return Natural is
      begin
         for K in I + 2 .. Sql'Last - 1 loop
            if Sql (K .. K + 1) = Mark then
               return K + 2;
            end if;
         end loop;
         return Sql'Last + 1;
      end Pair_End;

   begin
      case Sql (I) is
         when ''' =>
            --  A backslash always escapes; '' is a doubled quote.
            J := I + 1;
            while J <= Sql'Last loop
               if Sql (J) = '\' then
                  J := J + 2;
               elsif Sql (J) = ''' then
                  if J < Sql'Last and then Sql (J + 1) = ''' then
                     J := J + 2;
                  else
                     return J + 1;
                  end if;
               else
                  J := J + 1;
               end if;
            end loop;
            return Sql'Last + 1;
         when '"' =>
            J := I + 1;
            while J <= Sql'Last loop
               if Sql (J) = '"' then
                  if J < Sql'Last and then Sql (J + 1) = '"' then
                     J := J + 2;
                  else
                     return J + 1;
                  end if;
               else
                  J := J + 1;
               end if;
            end loop;
            return Sql'Last + 1;
         when '-' =>
            return (if Next = '-' then Line_End else 0);
         when '/' =>
            if Next = '/' then
               return Line_End;
            elsif Next = '*' then
               return Pair_End ("*/");
            end if;
            return 0;
         when '$' =>
            return (if Next = '$' then Pair_End ("$$") else 0);
         when others =>
            return 0;
      end case;
   end Skip_Non_Code;

   --  Calls Visit with each top-level statement of Sql.
   generic
      with procedure Visit (Statement : String);
   procedure For_Each_Statement (Sql : String);

   procedure For_Each_Statement (Sql : String) is
      Start : Natural := Sql'First;
      I     : Natural := Sql'First;
   begin
      while I <= Sql'Last loop
         declare
            Past : constant Natural := Skip_Non_Code (Sql, I);
         begin
            if Past > 0 then
               I := Past;
            elsif Sql (I) = ';' then
               Visit (Sql (Start .. I - 1));
               I := I + 1;
               Start := I;
            else
               I := I + 1;
            end if;
         end;
      end loop;
      Visit (Sql (Start .. Sql'Last));
   end For_Each_Statement;

   function Is_Word_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$'
      or else Character'Pos (C) >= 128);

   type Word_List is array (1 .. 16) of Unbounded_String;

   --  Up to Words'Length leading words of Statement, upper-cased, stepping
   --  over whitespace and comments and stopping at the first thing that is
   --  not a word.
   procedure Leading_Words
     (Statement : String;
      Words     : out Word_List;
      Count     : out Natural)
   is
      I : Natural := Statement'First;
   begin
      Count := 0;
      while I <= Statement'Last and then Count < Words'Length loop
         declare
            C    : constant Character := Statement (I);
            Next : constant Character :=
              (if I < Statement'Last then Statement (I + 1)
               else Character'Val (0));
         begin
            if Is_Space (C) then
               I := I + 1;
            elsif (C = '-' and then Next = '-')
              or else (C = '/' and then (Next = '/' or else Next = '*'))
            then
               I := Skip_Non_Code (Statement, I);
            elsif Is_Word_Char (C) then
               declare
                  Start : constant Positive := I;
               begin
                  while I <= Statement'Last
                    and then Is_Word_Char (Statement (I))
                  loop
                     I := I + 1;
                  end loop;
                  Count := Count + 1;
                  Words (Count) := Null_Unbounded_String;
                  for K in Start .. I - 1 loop
                     Append (Words (Count), Upper (Statement (K)));
                  end loop;
               end;
            else
               exit;
            end if;
         end;
      end loop;
   end Leading_Words;

   --  The words that may sit between CREATE/DROP/ALTER and the kind of
   --  object being named.
   function Is_Modifier (Word : String) return Boolean is
     (Word = "OR" or else Word = "REPLACE" or else Word = "TRANSIENT"
      or else Word = "TEMPORARY" or else Word = "TEMP"
      or else Word = "VOLATILE" or else Word = "LOCAL"
      or else Word = "GLOBAL" or else Word = "SECURE" or else Word = "IF"
      or else Word = "NOT" or else Word = "EXISTS" or else Word = "PUBLIC"
      or else Word = "PRIVATE" or else Word = "ICEBERG"
      or else Word = "DYNAMIC" or else Word = "HYBRID"
      or else Word = "EVENT" or else Word = "RECURSIVE"
      or else Word = "MATERIALIZED" or else Word = "EXTERNAL");

   function Statement_Touches_Session (Statement : String) return Boolean
   is
      Words : Word_List;
      Count : Natural;
      Past  : Positive := 2;  --  the first word past the modifiers
   begin
      Leading_Words (Statement, Words, Count);
      if Count = 0 then
         return False;
      end if;
      declare
         Verb : constant String := To_String (Words (1));
      begin
         if Verb = "USE" or else Verb = "SET" or else Verb = "UNSET" then
            return True;
         end if;
         while Past <= Count
           and then Is_Modifier (To_String (Words (Past)))
         loop
            Past := Past + 1;
         end loop;
         declare
            Object : constant String :=
              (if Past <= Count then To_String (Words (Past)) else "");
         begin
            if Verb = "ALTER" then
               return Object = "SESSION";
            elsif Verb /= "CREATE" and then Verb /= "DROP" then
               return False;
            elsif Object = "DATABASE" or else Object = "SCHEMA" then
               return True;
            elsif Verb = "CREATE" then
               for K in 2 .. Past - 1 loop
                  declare
                     Word : constant String := To_String (Words (K));
                  begin
                     if Word = "TEMPORARY" or else Word = "TEMP"
                       or else Word = "VOLATILE"
                     then
                        return True;
                     end if;
                  end;
               end loop;
            end if;
            return False;
         end;
      end;
   end Statement_Touches_Session;

   function Statement_Effect (Statement : String) return Transaction_Change
   is
      Words : Word_List;
      Count : Natural;
   begin
      Leading_Words (Statement, Words, Count);
      if Count = 0 then
         return No_Change;
      end if;
      declare
         First  : constant String := To_String (Words (1));
         Second : constant String :=
           (if Count >= 2 then To_String (Words (2)) else "");
      begin
         if First = "BEGIN" then
            if Count = 1 or else Second = "TRANSACTION"
              or else Second = "WORK" or else Second = "NAME"
            then
               return Opens;
            end if;
            return No_Change;
         elsif First = "START" and then Second = "TRANSACTION" then
            return Opens;
         elsif First = "COMMIT" or else First = "ROLLBACK" then
            return Closes;
         end if;
         return No_Change;
      end;
   end Statement_Effect;

   function Touches_Session (Sql : String) return Boolean is
      Found : Boolean := False;

      procedure Visit (Statement : String) is
      begin
         if not Found and then Statement_Touches_Session (Statement) then
            Found := True;
         end if;
      end Visit;

      procedure Each is new For_Each_Statement (Visit);
   begin
      Each (Sql);
      return Found;
   end Touches_Session;

   function Transaction_Effect (Sql : String) return Transaction_Change is
      Effect : Transaction_Change := No_Change;

      procedure Visit (Statement : String) is
         Change : constant Transaction_Change := Statement_Effect (Statement);
      begin
         if Change /= No_Change then
            Effect := Change;
         end if;
      end Visit;

      procedure Each is new For_Each_Statement (Visit);
   begin
      Each (Sql);
      return Effect;
   end Transaction_Effect;

end Frostlake.Sql;
