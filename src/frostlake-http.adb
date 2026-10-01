pragma Ada_2022;

with Ada.Exceptions;
with Ada.Streams;

with GNAT.Sockets;

package body Frostlake.Http is

   use Ada.Strings.Unbounded;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Trimmed (Image : String) return String is
   begin
      if Image'Length > 0 and then Image (Image'First) = ' ' then
         return Image (Image'First + 1 .. Image'Last);
      end if;
      return Image;
   end Trimmed;

   function Lower (C : Character) return Character is
   begin
      if C in 'A' .. 'Z' then
         return Character'Val
           (Character'Pos (C) - Character'Pos ('A') + Character'Pos ('a'));
      end if;
      return C;
   end Lower;

   --  The address for Host: a numeric literal as itself, a name through
   --  the resolver.  A name the resolver cannot place leaves the endpoint
   --  Where as unreachable as a refused connection does.
   function Resolve
     (Host  : String;
      Where : String) return GNAT.Sockets.Inet_Addr_Type
   is
      use GNAT.Sockets;
   begin
      begin
         return Inet_Addr (Host);
      exception
         when Socket_Error =>
            null;
      end;
      declare
         Entry_Of : constant Host_Entry_Type := Get_Host_By_Name (Host);
      begin
         if Addresses_Length (Entry_Of) = 0 then
            raise Connection_Error with
              "cannot reach " & Where & ": no address for " & Host;
         end if;
         return Addresses (Entry_Of, 1);
      end;
   exception
      when E : Host_Error | Socket_Error =>
         raise Connection_Error with
           "cannot reach " & Where & ": "
           & Ada.Exceptions.Exception_Message (E);
   end Resolve;

   --  One whole request-response exchange on a fresh connection.
   function Do_Request
     (Host         : String;
      Port         : Positive;
      Request_Text : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply
   is
      use Ada.Streams;
      use GNAT.Sockets;

      Where : constant String :=
        Host & ':' & Trimmed (Positive'Image (Port));

      Sock : Socket_Type := No_Socket;

      procedure Drop is
      begin
         if Sock /= No_Socket then
            begin
               Close_Socket (Sock);
            exception
               when Socket_Error =>
                  null;
            end;
            Sock := No_Socket;
         end if;
      end Drop;

      procedure Send_All (Text : String) is
         Buffer : Stream_Element_Array (1 .. Stream_Element_Offset
                                              (Text'Length));
         First  : Stream_Element_Offset := Buffer'First;
         Last   : Stream_Element_Offset;
      begin
         for I in Text'Range loop
            Buffer (Stream_Element_Offset (I - Text'First) + 1) :=
              Stream_Element (Character'Pos (Text (I)));
         end loop;
         while First <= Buffer'Last loop
            Send_Socket (Sock, Buffer (First .. Buffer'Last), Last);
            First := Last + 1;
         end loop;
      end Send_All;

      Out_Reply      : Reply;
      Data           : Unbounded_String;
      Header_End     : Natural := 0;  --  index of the CRLFCRLF's first CR
      Scanned_Up_To  : Natural := 0;
      Content_Length : Integer := -1;

      --  Finds the end of the header block without rescanning what an
      --  earlier chunk already covered.
      procedure Look_For_Header_End is
         Total : constant Natural := Length (Data);
         Start : constant Natural := Natural'Max (1, Scanned_Up_To - 2);
      begin
         for I in Start .. Total - 3 loop
            if Element (Data, I) = Character'Val (13)
              and then Element (Data, I + 1) = Character'Val (10)
              and then Element (Data, I + 2) = Character'Val (13)
              and then Element (Data, I + 3) = Character'Val (10)
            then
               Header_End := I;
               return;
            end if;
         end loop;
         Scanned_Up_To := Natural'Max (Total, 1);
      end Look_For_Header_End;

      procedure Read_Headers_Meta is
         Head : constant String := Slice (Data, 1, Header_End - 1);
         Line_Start : Natural := Head'First;
      begin
         --  Status line: HTTP/1.x SP status SP reason.
         declare
            Space : Natural := 0;
         begin
            for I in Head'Range loop
               exit when Head (I) = Character'Val (13);
               if Head (I) = ' ' then
                  Space := I;
                  exit;
               end if;
            end loop;
            if Space = 0 or else Space + 3 > Head'Last then
               raise Connection_Error with
                 "unintelligible response from " & Where;
            end if;
            declare
               Code : Natural := 0;
               Saw  : Boolean := False;
            begin
               for I in Space + 1 .. Head'Last loop
                  exit when Head (I) not in '0' .. '9';
                  --  A status code is three digits; a fourth makes it none.
                  if I - Space > 3 then
                     raise Connection_Error with
                       "unintelligible response from " & Where;
                  end if;
                  Code := Code * 10 + (Character'Pos (Head (I))
                                       - Character'Pos ('0'));
                  Saw := True;
               end loop;
               if not Saw then
                  raise Connection_Error with
                    "unintelligible response from " & Where;
               end if;
               Out_Reply.Status := Code;
            end;
         end;

         --  Header lines, for the one header this client reads.
         while Line_Start <= Head'Last loop
            declare
               Line_End : Natural := Head'Last;
               Colon    : Natural := 0;
            begin
               for I in Line_Start .. Head'Last - 1 loop
                  if Head (I) = Character'Val (13)
                    and then Head (I + 1) = Character'Val (10)
                  then
                     Line_End := I - 1;
                     exit;
                  end if;
               end loop;
               for I in Line_Start .. Line_End loop
                  if Head (I) = ':' then
                     Colon := I;
                     exit;
                  end if;
               end loop;
               if Colon > Line_Start then
                  declare
                     Name : String (1 .. Colon - Line_Start);
                  begin
                     for I in Name'Range loop
                        Name (I) := Lower (Head (Line_Start + I - 1));
                     end loop;
                     if Name = "content-length" then
                        --  Digits with nothing but whitespace around them;
                        --  anything else is no length at all.
                        declare
                           Pos   : Natural := Colon + 1;
                           Value : Natural := 0;
                           Digit : Natural;
                           Saw   : Boolean := False;
                        begin
                           while Pos <= Line_End
                             and then Head (Pos) in ' ' | Character'Val (9)
                           loop
                              Pos := Pos + 1;
                           end loop;
                           while Pos <= Line_End
                             and then Head (Pos) in '0' .. '9'
                           loop
                              Digit := Character'Pos (Head (Pos))
                                - Character'Pos ('0');
                              --  No length past Natural'Last is readable.
                              if Value > (Natural'Last - Digit) / 10 then
                                 raise Connection_Error with
                                   "unintelligible response from " & Where;
                              end if;
                              Value := Value * 10 + Digit;
                              Saw := True;
                              Pos := Pos + 1;
                           end loop;
                           while Pos <= Line_End
                             and then Head (Pos) in ' ' | Character'Val (9)
                           loop
                              Pos := Pos + 1;
                           end loop;
                           if not Saw or else Pos <= Line_End then
                              raise Connection_Error with
                                "unintelligible response from " & Where;
                           end if;
                           Content_Length := Value;
                        end;
                     end if;
                  end;
               end if;
               Line_Start := Line_End + 3;
            end;
         end loop;
      end Read_Headers_Meta;

   begin
      declare
         Address : constant Inet_Addr_Type := Resolve (Host, Where);
         --  Assembled by component: Sock_Addr_Type has a variant part, so
         --  an aggregate would need a static family.
         Server  : Sock_Addr_Type (Address.Family);
         Status  : Selector_Status;
      begin
         Server.Addr := Address;
         Server.Port := Port_Type (Port);
         Create_Socket (Sock, Address.Family, Socket_Stream);
         Set_Socket_Option
           (Sock, Socket_Level,
            (Name => Receive_Timeout, Timeout => Read_Timeout));
         Set_Socket_Option
           (Sock, Socket_Level,
            (Name => Send_Timeout, Timeout => Read_Timeout));
         Connect_Socket (Sock, Server, Timeout => Open_Timeout,
                         Status => Status);
         if Status /= Completed then
            Drop;
            raise Connection_Error with
              "cannot reach " & Where & ": connect timed out";
         end if;
      exception
         when E : Socket_Error | Host_Error =>
            Drop;
            raise Connection_Error with
              "cannot reach " & Where & ": "
              & Ada.Exceptions.Exception_Message (E);
      end;

      begin
         Send_All (Request_Text);

         declare
            Buffer : Stream_Element_Array (1 .. 32_768);
            Last   : Stream_Element_Offset;
         begin
            loop
               Receive_Socket (Sock, Buffer, Last);
               exit when Last < Buffer'First;
               for I in Buffer'First .. Last loop
                  Append (Data, Character'Val (Natural (Buffer (I))));
               end loop;
               if Header_End = 0 then
                  Look_For_Header_End;
                  if Header_End > 0 then
                     Read_Headers_Meta;
                  end if;
               end if;
               --  With the length known there is nothing to wait for
               --  past it — the server is closing this connection anyway.
               exit when Header_End > 0
                 and then Content_Length >= 0
                 and then Length (Data) - (Header_End + 3)
                            >= Content_Length;
            end loop;
         end;
      exception
         when E : Socket_Error =>
            Drop;
            raise Connection_Error with
              "request to " & Where & " failed: "
              & Ada.Exceptions.Exception_Message (E);
      end;
      Drop;

      if Header_End = 0 then
         raise Connection_Error with
           "unintelligible response from " & Where;
      end if;

      declare
         Body_First : constant Natural := Header_End + 4;
         Have       : constant Integer := Length (Data) - Body_First + 1;
      begin
         if Content_Length >= 0 then
            if Have < Content_Length then
               raise Connection_Error with
                 "truncated response from " & Where;
            end if;
            Out_Reply.Content := To_Unbounded_String
              (Slice (Data, Body_First,
                      Body_First + Content_Length - 1));
         elsif Have > 0 then
            Out_Reply.Content := To_Unbounded_String
              (Slice (Data, Body_First, Length (Data)));
         end if;
      end;
      return Out_Reply;
   exception
      when others =>
         --  Whatever ends the exchange early, an unintelligible status line
         --  from Read_Headers_Meta among them, takes the socket with it:
         --  GNAT.Sockets never closes one by itself.
         Drop;
         raise;
   end Do_Request;

   function Post
     (Host         : String;
      Port         : Positive;
      Path         : String;
      Content      : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply
   is
      Request_Text : constant String :=
        "POST " & Path & " HTTP/1.1" & CRLF
        & "Host: " & Host & ':' & Trimmed (Positive'Image (Port)) & CRLF
        & "Connection: close" & CRLF
        & "Accept: application/json" & CRLF
        & "Content-Type: application/json" & CRLF
        & "Content-Length: " & Trimmed (Natural'Image (Content'Length))
        & CRLF & CRLF
        & Content;
   begin
      return Do_Request (Host, Port, Request_Text,
                         Open_Timeout, Read_Timeout);
   end Post;

   function Get
     (Host         : String;
      Port         : Positive;
      Path         : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply
   is
      Request_Text : constant String :=
        "GET " & Path & " HTTP/1.1" & CRLF
        & "Host: " & Host & ':' & Trimmed (Positive'Image (Port)) & CRLF
        & "Connection: close" & CRLF
        & "Accept: application/json" & CRLF
        & CRLF;
   begin
      return Do_Request (Host, Port, Request_Text,
                         Open_Timeout, Read_Timeout);
   end Get;

   function Delete
     (Host         : String;
      Port         : Positive;
      Path         : String;
      Open_Timeout : Duration;
      Read_Timeout : Duration) return Reply
   is
      Request_Text : constant String :=
        "DELETE " & Path & " HTTP/1.1" & CRLF
        & "Host: " & Host & ':' & Trimmed (Positive'Image (Port)) & CRLF
        & "Connection: close" & CRLF
        & "Accept: application/json" & CRLF
        & CRLF;
   begin
      return Do_Request (Host, Port, Request_Text,
                         Open_Timeout, Read_Timeout);
   end Delete;

end Frostlake.Http;
