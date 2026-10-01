--  A small JSON document reader for the testkit corpus runner: it reads the
--  suite files, and decodes a semi-structured cell one level.  The driver's
--  own JSON layer reads the response of POST /api/execute and nothing else,
--  so the runner carries this general one — still GNAT's runtime only, like
--  the driver itself.
--
--  A document is parsed once into a flat table of nodes; a Node names one
--  value in it.  Strings come back as UTF-8, with every escape decoded;
--  numbers keep the digits they were written with.

private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

package Testkit_Json is

   Parse_Error : exception;

   type Value_Kind is
     (Null_Value,
      Boolean_Value,
      Number_Value,
      String_Value,
      Array_Value,
      Object_Value);

   type Node is new Natural;
   No_Node : constant Node := 0;
   --  "Absent": what Member answers for a key that is not there.

   type Document is private;

   function Parse (Text : String) return Document;
   --  Text must hold exactly one JSON value, with nothing but whitespace
   --  around it; anything else raises Parse_Error.

   function Root (Doc : Document) return Node;

   function Kind (Doc : Document; Item : Node) return Value_Kind;
   --  No_Node reads as Null_Value.

   function Member (Doc : Document; Item : Node; Key : String) return Node;
   --  The value of Item's member Key, or No_Node when Item is not an object
   --  or has no such member.  A key written twice means its last value, as
   --  a map reads it.

   function Has_Member (Doc : Document; Item : Node; Key : String)
      return Boolean;
   --  Whether Item is an object with a member Key — even one whose value is
   --  null.

   function Length (Doc : Document; Item : Node) return Natural;
   --  The element count of an array, or the member count of an object; 0
   --  for anything else.

   function Element (Doc : Document; Item : Node; Index : Positive)
      return Node;
   --  The Index-th element of an array, or the value of the Index-th member
   --  of an object, counted from 1 in document order.

   function Key (Doc : Document; Item : Node) return String;
   --  The member name Item was written under, when it is the value of an
   --  object's member; the empty string otherwise.

   function Text (Doc : Document; Item : Node) return String;
   --  A string's content, a number's own digits, "true" or "false"; the
   --  empty string for null, an array, an object or No_Node.

   function Is_True (Doc : Document; Item : Node) return Boolean;
   --  Whether Item is the literal true.

private

   use Ada.Strings.Unbounded;

   type Node_Record is record
      Kind : Value_Kind := Null_Value;
      Text : Unbounded_String;   --  string content, or a number's digits
      Key  : Unbounded_String;   --  the member name, inside an object
      Truth : Boolean := False;
      --  An array's or object's children occupy Children (First ..
      --  First + Count - 1), in document order.
      First : Positive := 1;
      Count : Natural := 0;
   end record;

   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node_Record);

   package Child_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node);

   type Document is record
      Nodes    : Node_Vectors.Vector;
      Children : Child_Vectors.Vector;
      Top      : Node := No_Node;
   end record;

end Testkit_Json;
