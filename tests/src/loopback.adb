with Ada.Containers.Vectors;
with Ada.Streams;
with Ada.Strings.Unbounded;

with GNAT.Sockets;

package body Loopback is

   use Ada.Strings.Unbounded;

   package String_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   protected State is
      procedure Configure
        (Status_Code : Natural;
         Content     : String;
         With_Length : Boolean);
      procedure Record_Request (Text : String);
      procedure Reset_Log;
      function Reply_Text return String;
      function Count return Natural;
      function Request (Index : Positive) return String;
   private
      Reply    : Unbounded_String;
      Requests : String_Vectors.Vector;
   end State;

   protected body State is

      procedure Configure
        (Status_Code : Natural;
         Content     : String;
         With_Length : Boolean)
      is
         CRLF : constant String :=
           Character'Val (13) & Character'Val (10);
         Head : Unbounded_String;

         function Trimmed (Image : String) return String is
         begin
            if Image'Length > 0 and then Image (Image'First) = ' ' then
               return Image (Image'First + 1 .. Image'Last);
            end if;
            return Image;
         end Trimmed;

      begin
         Append (Head, "HTTP/1.1 " & Trimmed (Natural'Image (Status_Code))
                 & " Whatever" & CRLF);
         Append (Head, "Content-Type: application/json" & CRLF);
         if With_Length then
            Append (Head, "Content-Length: "
                    & Trimmed (Natural'Image (Content'Length)) & CRLF);
         end if;
         Append (Head, "Connection: close" & CRLF & CRLF);
         Append (Head, Content);
         Reply := Head;
      end Configure;

      procedure Record_Request (Text : String) is
      begin
         Requests.Append (To_Unbounded_String (Text));
      end Record_Request;

      procedure Reset_Log is
      begin
         Requests.Clear;
      end Reset_Log;

      function Reply_Text return String is
      begin
         return To_String (Reply);
      end Reply_Text;

      function Count return Natural is
      begin
         return Natural (Requests.Length);
      end Count;

      function Request (Index : Positive) return String is
      begin
         if Index > Requests.Last_Index then
            return "";
         end if;
         return To_String (Requests.Element (Index));
      end Request;

   end State;

   Listener : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   Have_Listener : Boolean := False;

   --  Closing a listening socket does NOT wake a task blocked in accept
   --  on Linux, so the acceptor polls with a short timeout and watches
   --  this flag instead.
   protected Control is
      procedure Request_Stop;
      function Stopping return Boolean;
      procedure Mark_Done;
      function Done return Boolean;
      procedure Reset;
   private
      Stop_Flag : Boolean := False;
      Done_Flag : Boolean := True;
   end Control;

   protected body Control is

      procedure Request_Stop is
      begin
         Stop_Flag := True;
      end Request_Stop;

      function Stopping return Boolean is
      begin
         return Stop_Flag;
      end Stopping;

      procedure Mark_Done is
      begin
         Done_Flag := True;
      end Mark_Done;

      function Done return Boolean is
      begin
         return Done_Flag;
      end Done;

      procedure Reset is
      begin
         Stop_Flag := False;
         Done_Flag := False;
      end Reset;

   end Control;

   task type Acceptor_Task;
   type Acceptor_Access is access Acceptor_Task;

   task body Acceptor_Task is
      use Ada.Streams;
      use GNAT.Sockets;

      My_Socket : constant Socket_Type := Listener;

      function Header_Break (Text : Unbounded_String) return Natural is
      begin
         for I in 1 .. Length (Text) - 3 loop
            if Element (Text, I) = Character'Val (13)
              and then Element (Text, I + 1) = Character'Val (10)
              and then Element (Text, I + 2) = Character'Val (13)
              and then Element (Text, I + 3) = Character'Val (10)
            then
               return I;
            end if;
         end loop;
         return 0;
      end Header_Break;

      function Content_Length_Of (Head : String) return Integer is
         Needle : constant String := "content-length:";
         Lowered : String (Head'Range);
      begin
         for I in Head'Range loop
            if Head (I) in 'A' .. 'Z' then
               Lowered (I) := Character'Val
                 (Character'Pos (Head (I)) - Character'Pos ('A')
                  + Character'Pos ('a'));
            else
               Lowered (I) := Head (I);
            end if;
         end loop;
         for I in Lowered'First .. Lowered'Last - Needle'Length + 1 loop
            if Lowered (I .. I + Needle'Length - 1) = Needle then
               declare
                  Value : Natural := 0;
                  J     : Natural := I + Needle'Length;
               begin
                  while J <= Lowered'Last
                    and then Lowered (J) not in '0' .. '9'
                    and then Lowered (J) /= Character'Val (13)
                  loop
                     J := J + 1;
                  end loop;
                  while J <= Lowered'Last
                    and then Lowered (J) in '0' .. '9'
                  loop
                     Value := Value * 10
                       + (Character'Pos (Lowered (J))
                          - Character'Pos ('0'));
                     J := J + 1;
                  end loop;
                  return Value;
               end;
            end if;
         end loop;
         return -1;
      end Content_Length_Of;

   begin
      loop
         exit when Control.Stopping;
         declare
            Client : Socket_Type;
            From   : Sock_Addr_Type;
            pragma Warnings (Off, From);
            Answer : Selector_Status;
            Data   : Unbounded_String;
            Break  : Natural := 0;
            Wanted : Integer := -1;
         begin
            Accept_Socket (My_Socket, Client, From,
                           Timeout => 0.1, Status => Answer);
            if Answer = Completed then
               begin
               Set_Socket_Option
                 (Client, Socket_Level,
                  (Name => Receive_Timeout, Timeout => 5.0));
               declare
                  Buffer : Stream_Element_Array (1 .. 16_384);
                  Last   : Stream_Element_Offset;
               begin
                  Reading : loop
                     Receive_Socket (Client, Buffer, Last);
                     exit Reading when Last < Buffer'First;
                     for I in Buffer'First .. Last loop
                        Append (Data, Character'Val (Natural (Buffer (I))));
                     end loop;
                     if Break = 0 then
                        Break := Header_Break (Data);
                        if Break > 0 then
                           Wanted := Content_Length_Of
                             (Slice (Data, 1, Break - 1));
                        end if;
                     end if;
                     if Break > 0 then
                        exit Reading when Wanted <= 0
                          or else Length (Data) - (Break + 3) >= Wanted;
                     end if;
                  end loop Reading;
               end;
               State.Record_Request (To_String (Data));
               declare
                  Reply  : constant String := State.Reply_Text;
                  Buffer : Stream_Element_Array
                    (1 .. Stream_Element_Offset (Reply'Length));
                  First  : Stream_Element_Offset := Buffer'First;
                  Last   : Stream_Element_Offset;
               begin
                  for I in Reply'Range loop
                     Buffer (Stream_Element_Offset (I - Reply'First + 1))
                       := Stream_Element (Character'Pos (Reply (I)));
                  end loop;
                  while First <= Buffer'Last loop
                     Send_Socket (Client, Buffer (First .. Buffer'Last),
                                  Last);
                     First := Last + 1;
                  end loop;
               end;
               Close_Socket (Client);
               exception
                  when Socket_Error =>
                     begin
                        Close_Socket (Client);
                     exception
                        when Socket_Error =>
                           null;
                     end;
               end;
            end if;
         end;
      end loop;
      begin
         Close_Socket (My_Socket);
      exception
         when Socket_Error =>
            null;
      end;
      Control.Mark_Done;
   exception
      when others =>
         begin
            Close_Socket (My_Socket);
         exception
            when Socket_Error =>
               null;
         end;
         Control.Mark_Done;
   end Acceptor_Task;

   procedure Start
     (Content        : String;
      Port           : out Positive;
      Status         : Natural := 200;
      Content_Length : Boolean := True)
   is
      use GNAT.Sockets;
      Address      : Sock_Addr_Type;
      --  The access type is library-level, so the allocated task's master
      --  is the library — Start does not wait for it.
      New_Acceptor : Acceptor_Access;
      pragma Warnings (Off, New_Acceptor);
   begin
      Stop;
      State.Configure (Status, Content, Content_Length);
      State.Reset_Log;
      Create_Socket (Listener);
      Set_Socket_Option
        (Listener, Socket_Level, (Name => Reuse_Address, Enabled => True));
      Bind_Socket
        (Listener,
         (Family => Family_Inet,
          Addr   => Inet_Addr ("127.0.0.1"),
          Port   => 0));
      Listen_Socket (Listener);
      Address := Get_Socket_Name (Listener);
      Port := Positive (Address.Port);
      Have_Listener := True;
      Control.Reset;
      New_Acceptor := new Acceptor_Task;
   end Start;

   procedure Stop is
      use GNAT.Sockets;
   begin
      if Have_Listener then
         Control.Request_Stop;
         --  The task closes the listener itself once it notices; waiting
         --  here keeps Start/Stop cycles strictly sequential.
         for Attempt in 1 .. 200 loop
            exit when Control.Done;
            delay 0.02;
         end loop;
         Listener := No_Socket;
         Have_Listener := False;
      end if;
   end Stop;

   function Request_Count return Natural is
   begin
      return State.Count;
   end Request_Count;

   function Request_Text (Index : Positive) return String is
   begin
      return State.Request (Index);
   end Request_Text;

end Loopback;
