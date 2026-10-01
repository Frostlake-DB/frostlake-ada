package body Testkit_Json is

   function Is_Digit (C : Character) return Boolean is
     (C in '0' .. '9');

   --  The ASCII part of what Java's Character.isWhitespace accepts, which is
   --  what the reference runner skips between tokens.
   function Is_Space (C : Character) return Boolean is
     (C = ' '
      or else C in Character'Val (9) .. Character'Val (13)
      or else C in Character'Val (16#1C#) .. Character'Val (16#1F#));

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
         Append (Buffer, Character'Val (16#80# + (Code / 2**12) mod 2**6));
         Append (Buffer, Character'Val (16#80# + (Code / 2**6) mod 2**6));
         Append (Buffer, Character'Val (16#80# + Code mod 2**6));
      end if;
   end Append_Code_Point;

   -----------
   -- Parse --
   -----------

   function Parse (Text : String) return Document is
      Doc : Document;
      Pos : Natural := Text'First;

      procedure Fail (Message : String) with No_Return;

      procedure Fail (Message : String) is
      begin
         raise Parse_Error with Message & " at offset"
           & Natural'Image (Pos - Text'First);
      end Fail;

      procedure Skip_Space is
      begin
         while Pos <= Text'Last and then Is_Space (Text (Pos)) loop
            Pos := Pos + 1;
         end loop;
      end Skip_Space;

      function Peek return Character is
      begin
         if Pos > Text'Last then
            Fail ("unexpected end");
         end if;
         return Text (Pos);
      end Peek;

      procedure Expect (C : Character) is
      begin
         if Peek /= C then
            Fail ("expected '" & C & "'");
         end if;
         Pos := Pos + 1;
      end Expect;

      procedure Expect_Word (Word : String) is
      begin
         if Pos + Word'Length - 1 > Text'Last
           or else Text (Pos .. Pos + Word'Length - 1) /= Word
         then
            Fail ("expected " & Word);
         end if;
         Pos := Pos + Word'Length;
      end Expect_Word;

      function Hex4 return Natural is
         Value : Natural := 0;
      begin
         for Count in 1 .. 4 loop
            declare
               Digit : constant Natural := Hex_Value (Peek);
            begin
               if Digit > 15 then
                  Fail ("bad \u escape");
               end if;
               Value := Value * 16 + Digit;
               Pos := Pos + 1;
            end;
         end loop;
         return Value;
      end Hex4;

      function Parse_String return Unbounded_String is
         Buffer : Unbounded_String;
      begin
         Expect ('"');
         loop
            declare
               C : constant Character := Peek;
            begin
               Pos := Pos + 1;
               if C = '"' then
                  return Buffer;
               elsif C /= '\' then
                  Append (Buffer, C);
               else
                  declare
                     Escaped : constant Character := Peek;
                  begin
                     Pos := Pos + 1;
                     case Escaped is
                        when '"' | '\' | '/' =>
                           Append (Buffer, Escaped);
                        when 'b' =>
                           Append (Buffer, Character'Val (8));
                        when 'f' =>
                           Append (Buffer, Character'Val (12));
                        when 'n' =>
                           Append (Buffer, Character'Val (10));
                        when 'r' =>
                           Append (Buffer, Character'Val (13));
                        when 't' =>
                           Append (Buffer, Character'Val (9));
                        when 'u' =>
                           declare
                              Code : Natural := Hex4;
                           begin
                              --  A high surrogate pairs with the \u escape
                              --  that follows it.
                              if Code in 16#D800# .. 16#DBFF#
                                and then Pos + 1 <= Text'Last
                                and then Text (Pos) = '\'
                                and then Text (Pos + 1) = 'u'
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
                           Fail ("bad escape \" & Escaped);
                     end case;
                  end;
               end if;
            end;
         end loop;
      end Parse_String;

      function Parse_Number return String is
         Start : constant Natural := Pos;

         procedure Run_Of_Digits is
         begin
            if not Is_Digit (Peek) then
               Fail ("bad number");
            end if;
            while Pos <= Text'Last and then Is_Digit (Text (Pos)) loop
               Pos := Pos + 1;
            end loop;
         end Run_Of_Digits;

      begin
         if Peek = '-' then
            Pos := Pos + 1;
         end if;
         Run_Of_Digits;
         if Pos <= Text'Last and then Text (Pos) = '.' then
            Pos := Pos + 1;
            Run_Of_Digits;
         end if;
         if Pos <= Text'Last
           and then (Text (Pos) = 'e' or else Text (Pos) = 'E')
         then
            Pos := Pos + 1;
            if Peek = '+' or else Peek = '-' then
               Pos := Pos + 1;
            end if;
            Run_Of_Digits;
         end if;
         return Text (Start .. Pos - 1);
      end Parse_Number;

      function New_Node (Item : Node_Record) return Node is
      begin
         Doc.Nodes.Append (Item);
         return Node (Doc.Nodes.Last_Index);
      end New_Node;

      --  Files the children of a container, collected while it was read,
      --  as one contiguous run.
      procedure Adopt (Parent : Node; Found : Child_Vectors.Vector) is
         First : constant Positive := Doc.Children.Last_Index + 1;
      begin
         for Child of Found loop
            Doc.Children.Append (Child);
         end loop;
         Doc.Nodes (Positive (Parent)).First := First;
         Doc.Nodes (Positive (Parent)).Count := Natural (Found.Length);
      end Adopt;

      function Parse_Value return Node;

      function Parse_Array return Node is
         Self  : constant Node :=
           New_Node ((Kind => Array_Value, others => <>));
         Found : Child_Vectors.Vector;
      begin
         Expect ('[');
         Skip_Space;
         if Peek = ']' then
            Pos := Pos + 1;
         else
            loop
               Found.Append (Parse_Value);
               Skip_Space;
               exit when Peek = ']';
               Expect (',');
            end loop;
            Pos := Pos + 1;
         end if;
         Adopt (Self, Found);
         return Self;
      end Parse_Array;

      function Parse_Object return Node is
         Self  : constant Node :=
           New_Node ((Kind => Object_Value, others => <>));
         Found : Child_Vectors.Vector;
      begin
         Expect ('{');
         Skip_Space;
         if Peek = '}' then
            Pos := Pos + 1;
         else
            loop
               Skip_Space;
               if Peek /= '"' then
                  Fail ("expected a member name");
               end if;
               declare
                  Key   : constant Unbounded_String := Parse_String;
                  Value : Node;
               begin
                  Skip_Space;
                  Expect (':');
                  Value := Parse_Value;
                  Doc.Nodes (Positive (Value)).Key := Key;
                  Found.Append (Value);
               end;
               Skip_Space;
               exit when Peek = '}';
               Expect (',');
            end loop;
            Pos := Pos + 1;
         end if;
         Adopt (Self, Found);
         return Self;
      end Parse_Object;

      function Parse_Value return Node is
      begin
         Skip_Space;
         case Peek is
            when '{' =>
               return Parse_Object;
            when '[' =>
               return Parse_Array;
            when '"' =>
               return New_Node ((Kind => String_Value,
                                 Text => Parse_String,
                                 others => <>));
            when 't' =>
               Expect_Word ("true");
               return New_Node ((Kind => Boolean_Value, Truth => True,
                                 others => <>));
            when 'f' =>
               Expect_Word ("false");
               return New_Node ((Kind => Boolean_Value, Truth => False,
                                 others => <>));
            when 'n' =>
               Expect_Word ("null");
               return New_Node ((Kind => Null_Value, others => <>));
            when others =>
               return New_Node ((Kind => Number_Value,
                                 Text => To_Unbounded_String (Parse_Number),
                                 others => <>));
         end case;
      end Parse_Value;

   begin
      Doc.Top := Parse_Value;
      Skip_Space;
      if Pos <= Text'Last then
         Fail ("trailing content");
      end if;
      return Doc;
   end Parse;

   ---------------
   -- Accessors --
   ---------------

   function Root (Doc : Document) return Node is
     (Doc.Top);

   function Kind (Doc : Document; Item : Node) return Value_Kind is
   begin
      if Item = No_Node then
         return Null_Value;
      end if;
      return Doc.Nodes (Positive (Item)).Kind;
   end Kind;

   function Member (Doc : Document; Item : Node; Key : String) return Node
   is
      Found : Node := No_Node;
   begin
      if Kind (Doc, Item) /= Object_Value then
         return No_Node;
      end if;
      declare
         Parent : constant Node_Record := Doc.Nodes (Positive (Item));
      begin
         for Slot in Parent.First .. Parent.First + Parent.Count - 1 loop
            declare
               Child : constant Node := Doc.Children (Slot);
            begin
               if Doc.Nodes (Positive (Child)).Key = Key then
                  Found := Child;
               end if;
            end;
         end loop;
      end;
      return Found;
   end Member;

   function Has_Member (Doc : Document; Item : Node; Key : String)
      return Boolean is
     (Member (Doc, Item, Key) /= No_Node);

   function Length (Doc : Document; Item : Node) return Natural is
   begin
      if Kind (Doc, Item) not in Array_Value | Object_Value then
         return 0;
      end if;
      return Doc.Nodes (Positive (Item)).Count;
   end Length;

   function Element (Doc : Document; Item : Node; Index : Positive)
      return Node is
   begin
      if Index > Length (Doc, Item) then
         raise Constraint_Error with
           "no element" & Positive'Image (Index) & " in a container of"
           & Natural'Image (Length (Doc, Item));
      end if;
      return Doc.Children (Doc.Nodes (Positive (Item)).First + Index - 1);
   end Element;

   function Key (Doc : Document; Item : Node) return String is
   begin
      if Item = No_Node then
         return "";
      end if;
      return To_String (Doc.Nodes (Positive (Item)).Key);
   end Key;

   function Text (Doc : Document; Item : Node) return String is
   begin
      case Kind (Doc, Item) is
         when String_Value | Number_Value =>
            return To_String (Doc.Nodes (Positive (Item)).Text);
         when Boolean_Value =>
            return (if Doc.Nodes (Positive (Item)).Truth then "true"
                    else "false");
         when Null_Value | Array_Value | Object_Value =>
            return "";
      end case;
   end Text;

   function Is_True (Doc : Document; Item : Node) return Boolean is
     (Kind (Doc, Item) = Boolean_Value
      and then Doc.Nodes (Positive (Item)).Truth);

end Testkit_Json;
