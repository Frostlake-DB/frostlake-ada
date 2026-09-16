with Frostlake.Http;
with Frostlake.Sql;
with Frostlake.Wire;

package body Frostlake is

   use Ada.Strings.Unbounded;

   package Sql_Text renames Frostlake.Sql;

   ------------------------
   --  Small helpers     --
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

   function Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val
           (Character'Pos (C) - Character'Pos ('a') + Character'Pos ('A'));
      end if;
      return C;
   end Upper;

   function Lower_Text (Text : String) return String is
      Result : String (1 .. Text'Length);
   begin
      for I in Result'Range loop
         declare
            C : constant Character := Text (Text'First + I - 1);
         begin
            if C in 'A' .. 'Z' then
               Result (I) := Character'Val
                 (Character'Pos (C) - Character'Pos ('A')
                  + Character'Pos ('a'));
            else
               Result (I) := C;
            end if;
         end;
      end loop;
      return Result;
   end Lower_Text;

   function Equal_Insensitive (Left : String; Right : String)
      return Boolean is
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;
      for I in 0 .. Left'Length - 1 loop
         if Upper (Left (Left'First + I)) /= Upper (Right (Right'First + I))
         then
            return False;
         end if;
      end loop;
      return True;
   end Equal_Insensitive;

   Hex_Digit : constant array (0 .. 15) of Character := "0123456789ABCDEF";

   ------------------------
   --  Mutex             --
   ------------------------

   protected body Mutex_Type is

      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;

   end Mutex_Type;

   ------------------------
   --  Dates, timestamps --
   ------------------------

   function Image (Value : Date_Value) return String is
   begin
      return Padded (Value.Year, 4) & '-' & Padded (Value.Month, 2) & '-'
        & Padded (Value.Day, 2);
   end Image;

   function Image (Value : Timestamp_Value) return String is
      Core : constant String :=
        Padded (Value.Year, 4) & '-' & Padded (Value.Month, 2) & '-'
        & Padded (Value.Day, 2) & ' ' & Padded (Value.Hour, 2) & ':'
        & Padded (Value.Minute, 2) & ':' & Padded (Value.Second, 2)
        & '.' & Padded (Value.Nanosecond, 9);
   begin
      if not Value.Has_Offset then
         return Core;
      end if;
      declare
         Total : constant Natural := abs Value.Offset_Minutes;
         Sign  : constant Character :=
           (if Value.Offset_Minutes < 0 then '-' else '+');
      begin
         return Core & ' ' & Sign & Padded (Total / 60, 2)
           & Padded (Total mod 60, 2);
      end;
   end Image;

   ------------------------
   --  Cells             --
   ------------------------

   function Null_Cell return Cell is
   begin
      return (Kind => Null_Kind);
   end Null_Cell;

   function To_Cell (Value : Boolean) return Cell is
   begin
      return (Kind => Boolean_Kind, Bool => Value);
   end To_Cell;

   function To_Cell (Value : Long_Long_Integer) return Cell is
   begin
      return (Kind => Integer_Kind, Int => Value);
   end To_Cell;

   function To_Cell (Value : Long_Float) return Cell is
   begin
      return (Kind => Float_Kind, Real => Value);
   end To_Cell;

   function To_Cell (Value : String) return Cell is
   begin
      return (Kind => Text_Kind, Text => To_Unbounded_String (Value));
   end To_Cell;

   function To_Cell (Value : Date_Value) return Cell is
   begin
      return (Kind => Date_Kind, Date => Value);
   end To_Cell;

   function To_Cell (Value : Timestamp_Value) return Cell is
   begin
      return (Kind => Timestamp_Kind, Stamp => Value);
   end To_Cell;

   function To_Binary (Value : Ada.Streams.Stream_Element_Array)
      return Cell
   is
      Buffer : Unbounded_String;
   begin
      for I in Value'Range loop
         Append (Buffer, Character'Val (Natural (Value (I))));
      end loop;
      return (Kind => Binary_Kind, Bytes => Buffer);
   end To_Binary;

   function To_Decimal (Exact_Digits : String) return Cell is
   begin
      if not Sql_Text.Is_Numeric_Literal (Exact_Digits) then
         raise Usage_Error with
           "not a numeric literal: " & Exact_Digits;
      end if;
      return (Kind => Decimal_Kind,
              Exact => To_Unbounded_String (Exact_Digits));
   end To_Decimal;

   function To_Variant (Json_Text : String) return Cell is
   begin
      return (Kind => Variant_Kind, Json => To_Unbounded_String (Json_Text));
   end To_Variant;

   function Is_Null (Value : Cell) return Boolean is
   begin
      return Value.Kind = Null_Kind;
   end Is_Null;

   function Kind_Mismatch (Wanted : String; Value : Cell)
      return String is
   begin
      return "cell is not " & Wanted & " but "
        & Cell_Kind'Image (Value.Kind);
   end Kind_Mismatch;

   function As_Boolean (Value : Cell) return Boolean is
   begin
      if Value.Kind /= Boolean_Kind then
         raise Usage_Error with Kind_Mismatch ("a boolean", Value);
      end if;
      return Value.Bool;
   end As_Boolean;

   function As_Integer (Value : Cell) return Long_Long_Integer is
   begin
      case Value.Kind is
         when Integer_Kind =>
            return Value.Int;
         when Decimal_Kind =>
            declare
               V  : Long_Long_Integer;
               Ok : Boolean;
            begin
               Wire.To_Integer_If_Integral (To_String (Value.Exact), V, Ok);
               if Ok then
                  return V;
               end if;
               raise Usage_Error with
                 "cell is not integral: " & To_String (Value.Exact);
            end;
         when others =>
            raise Usage_Error with Kind_Mismatch ("an integer", Value);
      end case;
   end As_Integer;

   function As_Float (Value : Cell) return Long_Float is
   begin
      case Value.Kind is
         when Float_Kind =>
            return Value.Real;
         when Integer_Kind =>
            return Long_Float (Value.Int);
         when Decimal_Kind =>
            begin
               return Wire.To_Long_Float (To_String (Value.Exact));
            exception
               when Constraint_Error =>
                  raise Usage_Error with
                    "cell is not numeric: " & To_String (Value.Exact);
            end;
         when others =>
            raise Usage_Error with Kind_Mismatch ("numeric", Value);
      end case;
   end As_Float;

   function As_String (Value : Cell) return String is
   begin
      case Value.Kind is
         when Text_Kind =>
            return To_String (Value.Text);
         when Variant_Kind =>
            return To_String (Value.Json);
         when Decimal_Kind =>
            return To_String (Value.Exact);
         when others =>
            raise Usage_Error with Kind_Mismatch ("text", Value);
      end case;
   end As_String;

   function As_Date (Value : Cell) return Date_Value is
   begin
      if Value.Kind /= Date_Kind then
         raise Usage_Error with Kind_Mismatch ("a date", Value);
      end if;
      return Value.Date;
   end As_Date;

   function As_Timestamp (Value : Cell) return Timestamp_Value is
   begin
      if Value.Kind /= Timestamp_Kind then
         raise Usage_Error with Kind_Mismatch ("a timestamp", Value);
      end if;
      return Value.Stamp;
   end As_Timestamp;

   function As_Binary (Value : Cell)
      return Ada.Streams.Stream_Element_Array is
   begin
      if Value.Kind /= Binary_Kind then
         raise Usage_Error with Kind_Mismatch ("binary", Value);
      end if;
      declare
         Text   : constant String := To_String (Value.Bytes);
         Result : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      begin
         for I in Text'Range loop
            Result (Ada.Streams.Stream_Element_Offset (I - Text'First + 1))
              := Ada.Streams.Stream_Element (Character'Pos (Text (I)));
         end loop;
         return Result;
      end;
   end As_Binary;

   function Image (Value : Cell) return String is
   begin
      case Value.Kind is
         when Null_Kind =>
            return "NULL";
         when Boolean_Kind =>
            return (if Value.Bool then "TRUE" else "FALSE");
         when Integer_Kind =>
            return Trimmed (Long_Long_Integer'Image (Value.Int));
         when Decimal_Kind =>
            return To_String (Value.Exact);
         when Float_Kind =>
            return Trimmed (Long_Float'Image (Value.Real));
         when Text_Kind =>
            return To_String (Value.Text);
         when Date_Kind =>
            return Image (Value.Date);
         when Timestamp_Kind =>
            return Image (Value.Stamp);
         when Binary_Kind =>
            declare
               Text   : constant String := To_String (Value.Bytes);
               Result : String (1 .. Text'Length * 2);
               J      : Natural := 0;
            begin
               for I in Text'Range loop
                  J := J + 2;
                  Result (J - 1) :=
                    Hex_Digit (Character'Pos (Text (I)) / 16);
                  Result (J) := Hex_Digit (Character'Pos (Text (I)) mod 16);
               end loop;
               return Result;
            end;
         when Variant_Kind =>
            return To_String (Value.Json);
      end case;
   end Image;

   ------------------------
   --  Results           --
   ------------------------

   function Column_Count (From : Result) return Natural is
   begin
      return Natural (From.Columns.Length);
   end Column_Count;

   function Column_Name (From : Result; Index : Positive) return String is
   begin
      if Index > From.Columns.Last_Index then
         raise Usage_Error with
           "no column" & Positive'Image (Index) & " in a result of"
           & Natural'Image (Column_Count (From)) & " columns";
      end if;
      return To_String (From.Columns.Element (Index).Name);
   end Column_Name;

   function Column_Index (From : Result; Name : String) return Natural is
   begin
      for I in 1 .. From.Columns.Last_Index loop
         if To_String (From.Columns.Element (I).Name) = Name then
            return I;
         end if;
      end loop;
      for I in 1 .. From.Columns.Last_Index loop
         if Equal_Insensitive
              (To_String (From.Columns.Element (I).Name), Name)
         then
            return I;
         end if;
      end loop;
      return 0;
   end Column_Index;

   function Value (From : Result; Row : Positive; Col : Positive)
      return Cell is
   begin
      if Row > From.Rows.Last_Index then
         raise Usage_Error with
           "no row" & Positive'Image (Row) & " in a result of"
           & Natural'Image (Natural (From.Rows.Length)) & " rows";
      end if;
      if Col > From.Rows.Element (Row).Last_Index then
         raise Usage_Error with
           "no column" & Positive'Image (Col) & " in a result of"
           & Natural'Image (Column_Count (From)) & " columns";
      end if;
      return From.Rows.Element (Row).Element (Col);
   end Value;

   function Value (From : Result; Row : Positive; Name : String)
      return Cell
   is
      Index : constant Natural := Column_Index (From, Name);
   begin
      if Index = 0 then
         raise Usage_Error with "no such column: " & Name;
      end if;
      return Value (From, Row, Index);
   end Value;

   ------------------------
   --  DSN parsing       --
   ------------------------

   --  Everything the DSN query string may carry.  Anything else is a
   --  typo, and a typo in schema or read_timeout changes behaviour
   --  without saying so.
   Expected_List : constant String :=
     "ca_file, open_timeout, read_timeout, schema, session_idle_limit, "
     & "verify_ssl";

   function Percent_Decoded (Text : String) return String is
      Out_Text : Unbounded_String;
      I        : Natural := Text'First;

      function Hex_Of (C : Character) return Natural is
      begin
         case C is
            when '0' .. '9' =>
               return Character'Pos (C) - Character'Pos ('0');
            when 'a' .. 'f' =>
               return Character'Pos (C) - Character'Pos ('a') + 10;
            when 'A' .. 'F' =>
               return Character'Pos (C) - Character'Pos ('A') + 10;
            when others =>
               raise Usage_Error with
                 "invalid percent-escape in DSN: " & Text;
         end case;
      end Hex_Of;

   begin
      while I <= Text'Last loop
         if Text (I) = '+' then
            Append (Out_Text, ' ');
            I := I + 1;
         elsif Text (I) = '%' then
            if I + 2 > Text'Last then
               raise Usage_Error with
                 "invalid percent-escape in DSN: " & Text;
            end if;
            Append (Out_Text, Character'Val
                      (Hex_Of (Text (I + 1)) * 16 + Hex_Of (Text (I + 2))));
            I := I + 3;
         else
            Append (Out_Text, Text (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Out_Text);
   end Percent_Decoded;

   type Dsn_Parameter is record
      Present : Boolean := False;
      Text    : Unbounded_String;
   end record;

   type Dsn_Info is record
      Host     : Unbounded_String;
      Port     : Positive := Default_Port;
      Database : Unbounded_String;

      Schema             : Dsn_Parameter;
      Open_Timeout       : Dsn_Parameter;
      Read_Timeout       : Dsn_Parameter;
      Session_Idle_Limit : Dsn_Parameter;
   end record;

   function Parse_Dsn (Dsn : String) return Dsn_Info is
      Info : Dsn_Info;

      Scheme_End : Natural := 0;
   begin
      for I in Dsn'First .. Dsn'Last - 2 loop
         if Dsn (I .. I + 2) = "://" then
            Scheme_End := I;
            exit;
         end if;
      end loop;
      if Scheme_End = 0 then
         raise Usage_Error with
           "DSN must start with frostlake:// or http://";
      end if;

      declare
         Scheme : constant String :=
           Lower_Text (Dsn (Dsn'First .. Scheme_End - 1));
      begin
         if Scheme = "https" then
            raise Usage_Error with
              "https DSNs are not supported by the Ada driver; "
              & "the engine speaks plain HTTP";
         elsif Scheme = "http" then
            Info.Port := 80;
         elsif Scheme /= "frostlake" then
            raise Usage_Error with
              "DSN must start with frostlake:// or http://";
         end if;
      end;

      declare
         Rest_First    : constant Natural := Scheme_End + 3;
         Authority_End : Natural := Dsn'Last;
         Path_First    : Natural := 0;
         Query_First   : Natural := 0;
      begin
         for I in Rest_First .. Dsn'Last loop
            if Dsn (I) = '/' then
               Authority_End := I - 1;
               Path_First := I + 1;
               exit;
            elsif Dsn (I) = '?' then
               Authority_End := I - 1;
               Query_First := I + 1;
               exit;
            end if;
         end loop;
         if Path_First > 0 then
            for I in Path_First .. Dsn'Last loop
               if Dsn (I) = '?' then
                  Query_First := I + 1;
                  exit;
               end if;
            end loop;
         end if;

         --  Host and port.
         declare
            Authority : constant String := Dsn (Rest_First .. Authority_End);
            Host_Last : Natural := Authority'Last;
            Port_Text_First : Natural := 0;
         begin
            for I in Authority'Range loop
               if Authority (I) = '@' then
                  --  The server authenticates nobody, so credentials in a
                  --  DSN would be quietly dropped — and quietly dropping
                  --  a password is worse than saying so.
                  raise Usage_Error with
                    "the server takes no credentials; "
                    & "remove user:password from the DSN";
               end if;
            end loop;
            if Authority'Length = 0 then
               raise Usage_Error with "DSN is missing host[:port]";
            end if;
            if Authority (Authority'First) = '[' then
               declare
                  Closing : Natural := 0;
               begin
                  for I in Authority'Range loop
                     if Authority (I) = ']' then
                        Closing := I;
                        exit;
                     end if;
                  end loop;
                  if Closing = 0 then
                     raise Usage_Error with "invalid DSN: " & Dsn;
                  end if;
                  Info.Host := To_Unbounded_String
                    (Authority (Authority'First + 1 .. Closing - 1));
                  if Closing < Authority'Last then
                     if Authority (Closing + 1) /= ':' then
                        raise Usage_Error with "invalid DSN: " & Dsn;
                     end if;
                     Port_Text_First := Closing + 2;
                  end if;
               end;
            else
               for I in Authority'Range loop
                  if Authority (I) = ':' then
                     Host_Last := I - 1;
                     Port_Text_First := I + 1;
                     exit;
                  end if;
               end loop;
               Info.Host := To_Unbounded_String
                 (Authority (Authority'First .. Host_Last));
            end if;
            if Length (Info.Host) = 0 then
               raise Usage_Error with "DSN is missing host[:port]";
            end if;
            if Port_Text_First > 0 then
               declare
                  Port_Text : constant String :=
                    Authority (Port_Text_First .. Authority'Last);
                  Port_Bad  : constant String :=
                    "DSN port must be between 1 and 65535, got ";
                  Value     : Natural := 0;
               begin
                  if Port_Text'Length = 0 or else Port_Text'Length > 5 then
                     raise Usage_Error with Port_Bad & Port_Text;
                  end if;
                  for I in Port_Text'Range loop
                     if Port_Text (I) not in '0' .. '9' then
                        raise Usage_Error with Port_Bad & Port_Text;
                     end if;
                     Value := Value * 10
                       + (Character'Pos (Port_Text (I))
                          - Character'Pos ('0'));
                  end loop;
                  if Value < 1 or else Value > 65_535 then
                     raise Usage_Error with Port_Bad & Port_Text;
                  end if;
                  Info.Port := Value;
               end;
            end if;
         end;

         --  Database from the path.  A trailing slash is fine; a second
         --  segment means the caller meant something the DSN cannot
         --  express, and "db/extra" is not an identifier.
         if Path_First > 0 then
            declare
               Path_Last : Natural := Dsn'Last;
            begin
               if Query_First > 0 then
                  Path_Last := Query_First - 2;
               end if;
               declare
                  Path : constant String := Dsn (Path_First .. Path_Last);
                  Effective_Last : Natural := Path'Last;
               begin
                  if Path'Length > 0 and then Path (Path'Last) = '/' then
                     Effective_Last := Path'Last - 1;
                  end if;
                  for I in Path'First .. Effective_Last loop
                     if Path (I) = '/' then
                        raise Usage_Error with
                          "the DSN path names one database, got ""/"
                          & Path & '"';
                     end if;
                  end loop;
                  Info.Database := To_Unbounded_String
                    (Path (Path'First .. Effective_Last));
               end;
            end;
         end if;

         --  Query parameters.
         if Query_First > 0 then
            declare
               Q     : constant String := Dsn (Query_First .. Dsn'Last);
               Start : Natural := Q'First;

               Unknown : String_Vectors.Vector;

               procedure Take (Pair : String) is
                  Eq : Natural := 0;
               begin
                  if Pair'Length = 0 then
                     return;
                  end if;
                  for I in Pair'Range loop
                     if Pair (I) = '=' then
                        Eq := I;
                        exit;
                     end if;
                  end loop;
                  declare
                     Key : constant String := Percent_Decoded
                       (if Eq = 0 then Pair
                        else Pair (Pair'First .. Eq - 1));
                     Val : constant String := Percent_Decoded
                       (if Eq = 0 then ""
                        else Pair (Eq + 1 .. Pair'Last));
                  begin
                     if Key = "schema" then
                        Info.Schema :=
                          (True, To_Unbounded_String (Val));
                     elsif Key = "open_timeout" then
                        Info.Open_Timeout :=
                          (True, To_Unbounded_String (Val));
                     elsif Key = "read_timeout" then
                        Info.Read_Timeout :=
                          (True, To_Unbounded_String (Val));
                     elsif Key = "session_idle_limit" then
                        Info.Session_Idle_Limit :=
                          (True, To_Unbounded_String (Val));
                     elsif Key = "verify_ssl" or else Key = "ca_file" then
                        --  However they were spelled, they would do
                        --  nothing here.
                        raise Usage_Error with
                          "verify_ssl and ca_file apply to https DSNs "
                          & "only";
                     else
                        Unknown.Append (To_Unbounded_String (Key));
                     end if;
                  end;
               end Take;

            begin
               for I in Q'Range loop
                  if Q (I) = '&' then
                     Take (Q (Start .. I - 1));
                     Start := I + 1;
                  end if;
               end loop;
               Take (Q (Start .. Q'Last));

               if not Unknown.Is_Empty then
                  --  Sorted, so the message is stable however the DSN
                  --  ordered them.
                  declare
                     Names : Unbounded_String;
                  begin
                     for I in 1 .. Unknown.Last_Index loop
                        for J in I + 1 .. Unknown.Last_Index loop
                           if To_String (Unknown.Element (J))
                             < To_String (Unknown.Element (I))
                           then
                              Unknown.Swap (I, J);
                           end if;
                        end loop;
                     end loop;
                     for I in 1 .. Unknown.Last_Index loop
                        if I > 1 then
                           Append (Names, ", ");
                        end if;
                        Append (Names, Unknown.Element (I));
                     end loop;
                     raise Usage_Error with
                       "unknown DSN parameter: " & To_String (Names)
                       & " (expected " & Expected_List & ')';
                  end;
               end if;
            end;
         end if;
      end;
      return Info;
   end Parse_Dsn;

   function Parse_Seconds (Name : String; Text : String) return Duration
   is
   begin
      declare
         Real : Long_Float;
      begin
         begin
            Real := Wire.To_Long_Float (Text);
         exception
            when Constraint_Error =>
               raise Usage_Error with
                 Name & " must be a number of seconds, got """ & Text
                 & '"';
         end;
         begin
            return Duration (Real);
         exception
            when Constraint_Error =>
               raise Usage_Error with
                 Name & " must be a number of seconds, got """ & Text
                 & '"';
         end;
      end;
   end Parse_Seconds;

   function Duration_Text (Value : Duration) return String is
   begin
      return Trimmed (Duration'Image (Value));
   end Duration_Text;

   --  An explicit argument wins over the DSN, which wins over the
   --  default — and only the winner is validated, like the other
   --  drivers.
   function Timeout_For
     (Name     : String;
      Argument : Duration;
      From_Dsn : Dsn_Parameter;
      Fallback : Duration) return Duration is
   begin
      if Argument /= Unset then
         if Argument <= 0.0 then
            raise Usage_Error with
              Name & " must be positive, got " & Duration_Text (Argument);
         end if;
         return Argument;
      end if;
      if From_Dsn.Present then
         declare
            Given : constant Duration :=
              Parse_Seconds (Name, To_String (From_Dsn.Text));
         begin
            if Given <= 0.0 then
               raise Usage_Error with
                 Name & " must be positive, got "
                 & To_String (From_Dsn.Text);
            end if;
            return Given;
         end;
      end if;
      return Fallback;
   end Timeout_For;

   --  Zero switches the idle check off; anything else is seconds.
   function Idle_Limit_For
     (Argument : Duration;
      From_Dsn : Dsn_Parameter) return Duration is
   begin
      if Argument /= Unset then
         if Argument < 0.0 then
            raise Usage_Error with
              "session_idle_limit cannot be negative, got "
              & Duration_Text (Argument);
         end if;
         return Argument;
      end if;
      if From_Dsn.Present then
         declare
            Given : constant Duration :=
              Parse_Seconds ("session_idle_limit",
                             To_String (From_Dsn.Text));
         begin
            if Given < 0.0 then
               raise Usage_Error with
                 "session_idle_limit cannot be negative, got "
                 & To_String (From_Dsn.Text);
            end if;
            return Given;
         end;
      end if;
      return Default_Session_Idle_Limit;
   end Idle_Limit_For;

   ------------------------
   --  Connection core   --
   ------------------------

   procedure Check_Open (Conn : Connection) is
   begin
      if Conn.Closed then
         raise Usage_Error with "connection is closed";
      end if;
   end Check_Open;

   --  One statement over the wire; the caller holds the lock.
   function Round_Trip
     (Conn                  : in out Connection;
      Rendered              : String;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Wire.Response
   is
      Reply : constant Http.Reply :=
        Http.Post
          (Host         => To_String (Conn.Host),
           Port         => Conn.Port,
           Path         => "/api/execute",
           Content      => Wire.Build_Execute_Request
                             (Sql                   => Rendered,
                              Session_Id            =>
                                To_String (Conn.Session_Id),
                              Auto_Commit           => Conn.Auto_Commit,
                              Multi_Statement_Count =>
                                Multi_Statement_Count),
           Open_Timeout => Conn.Open_Timeout,
           Read_Timeout => Conn.Read_Timeout);
      Parsed : Wire.Response;
   begin
      --  Failed statements still answer with the error payload in the
      --  body, so the body is read regardless of the status code.
      begin
         Parsed := Wire.Parse_Response (To_String (Reply.Content));
      exception
         when Wire.Parse_Error =>
            raise Connection_Error with
              "HTTP" & Natural'Image (Reply.Status)
              & " with unreadable body";
      end;
      if Parsed.Has_Session_Id then
         Conn.Session_Id := Parsed.Session_Id;
      end if;
      if not Parsed.Success then
         if Parsed.Has_Error_Message then
            Conn.Last_Error := Parsed.Error_Message;
            raise Query_Error with To_String (Parsed.Error_Message);
         end if;
         Conn.Last_Error := To_Unbounded_String ("statement failed");
         raise Query_Error with "statement failed";
      end if;
      Conn.Last_Used_At := Ada.Real_Time.Clock;
      Conn.Has_Last_Used := True;
      return Parsed;
   end Round_Trip;

   --  The engine reaps a session once it has been idle long enough and
   --  then quietly builds a fresh one for the id we keep sending, losing
   --  the database and schema we selected.  Nothing in the reply gives it
   --  away, so past the limit the only safe reading is that the session
   --  is new, and the DSN's defaults go back on.  Not once the caller has
   --  selected something themselves: putting our defaults over their
   --  choice is its own surprise.
   procedure Restore_Session_Defaults (Conn : in out Connection) is
      use Ada.Real_Time;
   begin
      if Conn.Session_Defaults.Is_Empty or else Conn.Session_Touched then
         return;
      end if;
      if Conn.Idle_Limit = 0.0 or else not Conn.Has_Last_Used then
         return;
      end if;
      if To_Duration (Clock - Conn.Last_Used_At) < Conn.Idle_Limit then
         return;
      end if;
      for I in 1 .. Conn.Session_Defaults.Last_Index loop
         Conn.Pending_Use.Append (Conn.Session_Defaults.Element (I));
      end loop;
   end Restore_Session_Defaults;

   procedure Drain_Pending (Conn : in out Connection) is
   begin
      while not Conn.Pending_Use.Is_Empty loop
         declare
            Statement : constant String :=
              To_String (Conn.Pending_Use.First_Element);
         begin
            Conn.Pending_Use.Delete_First;
            declare
               Ignored : constant Wire.Response :=
                 Round_Trip (Conn, Statement);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end;
      end loop;
   end Drain_Pending;

   function Shaped (Sets : Result_Vectors.Vector)
      return Result_Vectors.Vector
   is
      Out_Sets : Result_Vectors.Vector;
   begin
      if Sets.Is_Empty then
         Out_Sets.Append (Result'(others => <>));
         return Out_Sets;
      end if;
      for I in 1 .. Sets.Last_Index loop
         declare
            Set : constant Result := Sets.Element (I);
         begin
            if Natural (Set.Rows.Length) = 1
              and then Wire.Is_Dml_Status (Set.Columns)
            then
               Out_Sets.Append
                 (Result'(Columns   => Column_Vectors.Empty_Vector,
                          Rows      => Row_Vectors.Empty_Vector,
                          Row_Count => Wire.Dml_Row_Count
                                         (Set.Columns,
                                          Set.Rows.Element (1))));
            else
               Out_Sets.Append (Set);
            end if;
         end;
      end loop;
      return Out_Sets;
   end Shaped;

   --  The pending USE statements and the statement itself have to reach
   --  the session as one unit: another task must not slip a query in
   --  between.  The caller holds the lock.
   function Locked_Execute_All
     (Conn                  : in out Connection;
      Original              : String;
      Rendered              : String;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Result_Vectors.Vector is
   begin
      Restore_Session_Defaults (Conn);
      --  Each pending USE is one statement of its own, whatever this call
      --  declares.
      Drain_Pending (Conn);
      declare
         Parsed : constant Wire.Response :=
           Round_Trip (Conn, Rendered, Multi_Statement_Count);
         Out_V  : constant Result_Vectors.Vector :=
           Shaped (Parsed.Result_Sets);
      begin
         if Sql_Text.Selects_Session_State (Original) then
            Conn.Session_Touched := True;
         end if;
         return Out_V;
      end;
   end Locked_Execute_All;

   ------------------------
   --  Public operations --
   ------------------------

   function Connect
     (Dsn                : String;
      Open_Timeout       : Duration := Unset;
      Read_Timeout       : Duration := Unset;
      Session_Idle_Limit : Duration := Unset) return Connection
   is
      Info : constant Dsn_Info := Parse_Dsn (Dsn);
   begin
      return Conn : Connection do
         Conn.Host := Info.Host;
         Conn.Port := Info.Port;
         Conn.Open_Timeout :=
           Timeout_For ("open_timeout", Open_Timeout,
                        Info.Open_Timeout, Default_Open_Timeout);
         Conn.Read_Timeout :=
           Timeout_For ("read_timeout", Read_Timeout,
                        Info.Read_Timeout, Default_Read_Timeout);
         Conn.Idle_Limit :=
           Idle_Limit_For (Session_Idle_Limit, Info.Session_Idle_Limit);

         if Length (Info.Database) > 0 then
            Conn.Pending_Use.Append
              (To_Unbounded_String
                 ("USE DATABASE "
                  & Sql_Text.Quote_Identifier (To_String (Info.Database))));
         end if;
         if Info.Schema.Present then
            Conn.Pending_Use.Append
              (To_Unbounded_String
                 ("USE SCHEMA "
                  & Sql_Text.Quote_Identifier
                      (To_String (Info.Schema.Text))));
         end if;
         Conn.Session_Defaults := Conn.Pending_Use;

         --  Applied here so a database that does not exist is reported
         --  by Connect rather than surfacing later on whatever query
         --  happens to run first.
         Ping (Conn);
         Conn.Lock.Seize;
         begin
            Drain_Pending (Conn);
         exception
            when others =>
               Conn.Lock.Release;
               raise;
         end;
         Conn.Lock.Release;
      end return;
   end Connect;

   procedure Ping (Conn : in out Connection) is
   begin
      Check_Open (Conn);
      declare
         Reply : constant Http.Reply :=
           Http.Get
             (Host         => To_String (Conn.Host),
              Port         => Conn.Port,
              Path         => "/api/health",
              Open_Timeout => Conn.Open_Timeout,
              Read_Timeout => Conn.Read_Timeout);
      begin
         if Reply.Status not in 200 .. 299 then
            raise Connection_Error with
              "server unhealthy: HTTP" & Natural'Image (Reply.Status);
         end if;
      end;
   end Ping;

   function Execute_All
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Result_Vectors.Vector
   is
      Rendered : constant String :=
        (if Binds'Length = 0 then Sql else Sql_Text.Substitute (Sql, Binds));
   begin
      Check_Open (Conn);
      if Multi_Statement_Count < No_Multi_Statement_Count then
         raise Usage_Error with
           "multi_statement_count must be 0 or more, got "
           & Trimmed (Integer'Image (Multi_Statement_Count));
      end if;
      Conn.Lock.Seize;
      begin
         declare
            Out_V : constant Result_Vectors.Vector :=
              Locked_Execute_All (Conn, Sql, Rendered,
                                  Multi_Statement_Count);
         begin
            Conn.Lock.Release;
            return Out_V;
         end;
      exception
         when others =>
            Conn.Lock.Release;
            raise;
      end;
   end Execute_All;

   function Execute
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
      return Result
   is
      All_Sets : constant Result_Vectors.Vector :=
        Execute_All (Conn, Sql, Binds, Multi_Statement_Count);
   begin
      return All_Sets.First_Element;
   end Execute;

   procedure Execute
     (Conn                  : in out Connection;
      Sql                   : String;
      Binds                 : Bind_Array := No_Binds;
      Multi_Statement_Count : Integer := No_Multi_Statement_Count)
   is
      Ignored : constant Result_Vectors.Vector :=
        Execute_All (Conn, Sql, Binds, Multi_Statement_Count);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Execute;

   procedure Begin_Transaction (Conn : in out Connection) is
   begin
      Check_Open (Conn);
      Conn.Lock.Seize;
      begin
         Conn.Auto_Commit := False;
         declare
            Ignored : constant Result_Vectors.Vector :=
              Locked_Execute_All (Conn, "BEGIN", "BEGIN");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when others =>
            Conn.Lock.Release;
            raise;
      end;
      Conn.Lock.Release;
   end Begin_Transaction;

   procedure Commit (Conn : in out Connection) is
   begin
      Check_Open (Conn);
      Conn.Lock.Seize;
      begin
         declare
            Ignored : constant Result_Vectors.Vector :=
              Locked_Execute_All (Conn, "COMMIT", "COMMIT");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
         Conn.Auto_Commit := True;
      exception
         when others =>
            Conn.Lock.Release;
            raise;
      end;
      Conn.Lock.Release;
   end Commit;

   procedure Rollback (Conn : in out Connection) is
   begin
      Check_Open (Conn);
      Conn.Lock.Seize;
      begin
         declare
            Ignored : constant Result_Vectors.Vector :=
              Locked_Execute_All (Conn, "ROLLBACK", "ROLLBACK");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
         Conn.Auto_Commit := True;
      exception
         when others =>
            Conn.Lock.Release;
            raise;
      end;
      Conn.Lock.Release;
   end Rollback;

   procedure Run_In_Transaction (Conn : in out Connection) is
   begin
      Begin_Transaction (Conn);
      begin
         Work (Conn);
         Commit (Conn);
      exception
         when others =>
            begin
               Rollback (Conn);
            exception
               when others =>
                  --  A failed rollback must not replace the exception
                  --  that caused it.
                  null;
            end;
            raise;
      end;
   end Run_In_Transaction;

   procedure Close (Conn : in out Connection) is
   begin
      --  No socket outlives a request, so closing is only a refusal to
      --  be used again.
      Conn.Closed := True;
   end Close;

   function Is_Closed (Conn : Connection) return Boolean is
   begin
      return Conn.Closed;
   end Is_Closed;

   function Last_Error_Message (Conn : Connection) return String is
   begin
      return To_String (Conn.Last_Error);
   end Last_Error_Message;

   overriding procedure Finalize (Conn : in out Connection) is
   begin
      Conn.Closed := True;
   end Finalize;

end Frostlake;
