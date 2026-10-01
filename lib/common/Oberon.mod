MODULE Oberon;
(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   ===========================================================================
   STOP.  READ THIS BEFORE YOU TOUCH ANYTHING IN THIS FILE.

   THE COMMENT BELOW IS THE MANUAL FOR OBJECT-ORIENTED PROGRAMMING IN THIS
   DIALECT.  IT IS NOT DECORATION, IT IS NOT A DRAFT, AND IT IS NOT SOMETHING
   A LATER READER IS EXPECTED TO IMPROVE.

       IT MUST NOT BE CHANGED, SHORTENED, REWRITTEN, TRANSLATED OR DELETED.

   If you believe a sentence in it is wrong, out of date, or incomplete:
   DO NOT EDIT IT.  Ask the owner of this repository for permission first,
   and say which sentence you think is wrong and what you would write
   instead.  The same holds for the tempting shortcut of deleting the
   comment and keeping the code - the reasoning is the deliverable here, and
   the code underneath it is the short and easy part.

   This prohibition covers this notice as well.  It does NOT cover the
   executable code below the comment: that may be changed whenever the
   manual says it should be, and the manual is what says how.
   =========================================================================== *)

(* THE ROOT OBJECT, AND THE WHOLE OF WHAT THIS DIALECT CALLS OBJECT-ORIENTED
   PROGRAMMING.  There is one type here, `Object`, and one method, `Done`, and
   every object in the library - a byte array, a list, a stream - is an
   extension of it.  A module that owns heap records and wants its callers to
   treat them as objects imports this and extends `ObjectDesc`; a caller that
   holds any object at all can end it with `Oberon.Done`, without knowing what
   it is.

   This manual is in three parts.  PART 1 is the pattern: what an object is,
   how a method is written, how one object extends another, and what an
   interface is.  PART 2 is lifetime: the constructor, the destructor, and the
   two halves of the agreement between an object and its caller.  PART 3 is
   everything else a writer of a class needs - the declaration order, a recipe
   to follow, and how the design is checked.


   =========================================================================
   PART 1 - THE PATTERN
   =========================================================================

   WHAT AN OBJECT IS HERE.  A record reached through a pointer, whose methods
   are procedure-typed FIELDS:

       T* = POINTER TO TDesc;
       TDesc* = RECORD
           x: INTEGER;
           M*: PROCEDURE (self: T)
       END;

   Each method is bound to a real procedure by the constructor - `t.M := M` -
   so the record carries its own method table and dispatch is a field load.
   An object is therefore an ordinary heap record that happens to have
   procedures in it, and everything the language says about records and
   pointers still holds: it can be passed, assigned, put in an array, and
   reached through any pointer type it is an extension of.

   WHY FIELDS AND NOT TYPE-BOUND PROCEDURES.  Because this compiler has none.
   The Oberon-07 form `PROCEDURE (v: T) M;` is refused here with
   `error (22) identifier expected` on the opening parenthesis, measured on
   the `win64con` target, and no module in this tree contains one.  The
   report's own mechanism would be shorter - an override would be a
   declaration, and the record would not grow by a pointer per method - but
   the compiler has to accept it first, and it does not.  So a method is a
   field, and this module is where that decision is written down rather than
   left for the next reader to rediscover.  `_probe/ObjBound.mod` is the
   measurement, kept as evidence and expected not to compile.

   THERE IS NO IMPLICIT RECEIVER.  With no type-bound procedures there is no
   `self` to bind, so a method is called as `t.M(t)` and never as `t.M()`.  It
   reads oddly for the first hour and then not at all: the receiver is an
   ordinary argument, and the field is an ordinary field, so nothing about the
   call is magic.  That is also why every constructor in the library installs
   its method fields - there is no compiler-generated table to fall back on,
   and a field left NIL is a trap reached by writing correct-looking code.

   INHERITANCE IS RECORD EXTENSION, AND IT IS THE ORDINARY KIND.  `RECORD
   (BaseDesc)` gives an extension every field of the base, so an extension
   inherits the base's method fields along with its state; a pointer to the
   extension assigns to a variable or parameter of the base pointer type,
   because the extension IS a base.  What inheritance does NOT give is an
   override: rebinding an inherited field is an assignment in a constructor,
   not a declaration, so the base's method runs until somebody binds over it.
   Measured with the rest of this paragraph - `_probe/ObjInh.mod`, which binds
   an inherited `Done` through a two-level extension, reaches it through a base
   variable, and shows that what the base variable finds is the extension's
   binding and not the base's.

   AN INTERFACE IS A BASE RECORD.  This is the half of the pattern that does
   the real work, and the half that is easy to leave out.  A record that
   declares method fields and no state is an interface: it says what may be
   asked of a thing, and nothing about how the thing answers.  Every
   implementation of it extends that record, declares its OWN STATE AND NO
   METHODS AT ALL, and binds the inherited method fields in its constructor.
   `lib/common/Streams.mod` is the worked example:

       InputDesc*  = RECORD (Oberon.ObjectDesc)
           Read*:  PROCEDURE (s: Input; VAR b: ARRAY OF BYTE) : INTEGER;
           ... four more ...
       END;

       FileInputDesc* = RECORD (InputDesc)
           file:   Files.File                    -- state, and only state
       END;

   and then, in the constructor, `s.Read := ReadInput; s.Skip := SkipInput;`
   and so on for every field the interface declared.  `FileInputDesc` and
   `MemInputDesc` declare one and two fields of state respectively and not a
   single method of their own.

   What that buys is the reason the ceremony exists: a caller can be handed an
   `Input` - from `OpenFileInput` or from `OpenMemInput`, it does not know
   which and does not ask - and call `s.Read(s, b)` on it.  Without the shared
   declaration there would be no type to write that caller against, because a
   procedure declared for `FileInput` cannot be stored in a field declared for
   `MemInput`, and the caller would have to be written twice.

   A SUBCLASS NEVER RE-DECLARES AN INHERITED FIELD.  The language forbids it,
   and there is no reason to want it: a second field of the same name is a
   second method table entry that nothing will bind, and for `Done` it would be
   a second destructor for the one object.  Measured over the whole tree: 41
   inheritance edges, no record anywhere re-declaring a field its base already
   has.  When a class seems to need one, what it actually needs is either a
   different name or a place in the base record.

   THE EXACT-TYPE-MATCH RULE, AND THE TYPE GUARD.  A procedure variable must
   match its field's type EXACTLY - not closely, not compatibly, exactly.  So
   the rule for the whole pattern is:

       a method field is declared with the pointer type of the record that
       declares it, and a procedure bound to it takes that same type.

   At the root, where `Done` is declared, that type is `Object`.  In an
   interface record, that type is the interface's own pointer.  A procedure
   written for a concrete class does not match either one, so the body of an
   implementation begins by narrowing the argument back down to itself with a
   type guard:

       PROCEDURE AvailableInput (s: Input): INTEGER;
       VAR f: FileInput; n: INTEGER;
       BEGIN
           f := s(FileInput);          -- the guard: s is known to be one
           n := Files.Size(f.file) - Files.Position(f.file);
           ...
       END AvailableInput;

   That one line is the entire price of the pattern, and it is paid once per
   method.  It is also the reason a class cannot be given a typed destructor
   of its own: `Done` is declared `PROCEDURE (self: Object)`, so every
   destructor in the tree takes `Object` and guards down the same way.

   WHEN TO DECLARE A SHARED ANCESTOR, AND WHEN NOT TO.  Declare one when some
   code must call a method WITHOUT KNOWING THE CONCRETE TYPE.  In `Streams`
   such a caller exists - `OpenFileInput` and `OpenMemInput` both answer an
   `Input` - so `Input` has to declare the five methods.  Where no such caller
   exists, do not declare one, however alike two classes look:
   `lib/common/Arrays.mod` holds `List` and `Map`, which between them share
   seven method names (`Capacity`, `Clear`, `Count`, `Get`, `Pack`, `Put`,
   `Remove`) and are deliberately SIBLINGS under `ObjectDesc` rather than
   children of a common container.  No code in this tree ever holds a `List`
   and a `Map` in one variable, so a common ancestor would buy nothing at all
   and cost an adapter per method per class - the guard-and-forward shown
   above, eight of them, against a call nobody makes.  Two collections that
   merely have methods with the same names are not one thing.


   =========================================================================
   PART 2 - LIFETIME
   =========================================================================

   THE CONSTRUCTOR'S OBLIGATIONS.  A constructor allocates with `NEW`, fills
   in the state, and then binds EVERY method field the object has, inherited
   ones included.  A field left unbound is not a default - it is NIL, and a
   call through it is a trap, so "I will bind it later" is a sentence that ends
   in a crash.  A constructor that cannot do its job answers NIL, and it must
   then be careful to give back anything it took before it failed; the
   constructors in `Streams` are the model, and the header of that module says
   why the answer is NIL rather than a flag.

   THE DESTRUCTOR IS MANDATORY, AND THAT IS THE WHOLE POINT OF IT.  There is
   no garbage collector in this language, no finalizer and no reference count:
   `NEW` is answered by `DISPOSE` alone, and nothing else will ever come along
   to pick up what a program forgot.  An object that is not destroyed keeps its
   record and everything the record owns - its blocks, its buffers, its open
   file - for the whole life of the process, and a long-running program that
   forgets one object per loop iteration simply runs out of memory.  So the
   rule is not a courtesy a caller may skip by being in a hurry:

       call Done on every object you created, exactly once, on every path
       out of the code that created it - including the paths that return
       early, and including the ones that only run when something failed.

   The second half of that sentence is the half that is usually got wrong.  An
   error path is where an object is most often dropped, and it is exactly where
   the object is most often holding something expensive.

   WHAT A DESTRUCTOR MUST DO.  Free everything the object owns, and then
   itself, in that order.  `DISPOSE(self)` is the last statement, and it is not
   optional and not movable: it is what answers the `NEW` in the constructor,
   which for a class whose methods are fields is the `NEW` that made the record
   the method table lives in.  The order matters because what an object owns
   may point back at the object, or hold a resource the object is the only
   remaining reference to - a stream closes its File before it frees the record
   that holds the File, because the close is what releases the page cache the
   File was holding.

   WHAT A DESTRUCTOR MUST NOT BE ASKED TO DO:

   - IT CANNOT BE CALLED TWICE.  Done is terminal.  The record is gone when it
     returns, so a second call on the same pointer is a use of freed memory and
     not a free no-op, and there is no flag left to make it safe - the flag
     would have had to live in the record that was just freed.

   - IT CANNOT NIL THE CALLER'S VARIABLE.  `DISPOSE` takes its argument by
     reference and NILs the variable it was handed, but a destructor reaches
     its object through a VALUE parameter (its type is `PROCEDURE (self:
     Object)`, and a VAR parameter could not be bound to that type), so all it
     can clear is its own local.  A caller that means to keep using its
     variable writes NIL into it after Done returns, and not instead of it.

   - IT CANNOT TAKE A DERIVED TYPE.  This is the exact-type-match rule again:
     the field here is `PROCEDURE (self: Object)`, so a destructor is declared
     `PROCEDURE DoneSomething (self: Object)` and guards its way back down with
     `s := self(Something)` before it touches a field.  That is the one piece
     of ceremony the dialect imposes on the pattern - see `ByteArr` for it
     written out.

   - IT MUST NOT BE ADDED A SECOND TIME UNDER ANOTHER NAME.  A class has one
     destructor, reached through the one inherited field.  `Streams` used to
     carry a `Closeable` interface with a `Close` method beside `Done`, and
     both were deleted when the root arrived: two names for one act is two
     things to keep in step, and a caller reading the module has to work out
     which one is the real one.  There is exactly one.

   AND THE CALLER'S HALF IS `Oberon.Done`.  It takes any object, ignores NIL,
   and calls the object's own `Done`:

       o := Something.Create(...);
       IF o # NIL THEN ... END;
       Oberon.Done(o);          -- and then o := NIL if you will use it again

   NIL is accepted so that the closing half of a caller's code needs no test of
   its own after a constructor that answers NIL on failure - which is what the
   constructors in this library do, and it is why the guard above is around the
   USE and not around the destroy.  A caller that keeps its variable writes NIL
   into it afterwards; nothing here can do that for it.

   `Oberon.Done` and the record's `Done` field do not collide, and a class may
   therefore have both a procedure and a field of that name in scope: the two
   are different namespaces, `Oberon.Done(o)` names the procedure and
   `o.Done(o)` names the field, and the compiler keeps them apart.  Measured -
   `_probe/ObjRoot.mod` calls both on one object and passes.

   THE DEFAULT OBJECT.  `Oberon.New()` makes a bare Object - a heap record with
   nothing in it but its method table, whose Done frees the record and stops.
   It is what an object with no state of its own is built on, and it is here so
   that Object is a type a program can actually instantiate rather than an
   abstract name it can only extend.


   =========================================================================
   PART 3 - THE REST
   =========================================================================

   WHAT THIS PATTERN GIVES, AND WHAT IT DOES NOT.

       It gives you:        It does not give you:
       -------------        --------------------
       extension            an override keyword - rebinding a field in a
                            constructor IS the override, and there is no
                            record of which class last did it
       a base pointer       abstract methods - an interface leaves a field
       that sees the        NIL, and calling it traps; nothing checks that a
       extension's          class bound every field before handing the object
       binding              to a caller
       one destructor       a destructor that runs by itself, ever
       for every object
       an interface as      a separate interface concept, or multiple
       a base record        inheritance - a record has one base, so an
                            interface is a base record and nothing else

   DECLARATION ORDER.  Two rules, both forced, both invisible until violated.
   A pointer type must be declared before the record it points to when a field
   of that record takes the pointer type - the cycle has to be broken somewhere
   and the pointer is the place.  And a procedure must be named before it is
   used, which is why every module here declares its destructors and its method
   implementations above its constructors, and why `DoneObject` stands above
   `New` in this file.

   HOW TO ADD A CLASS.  The recipe, in the order the compiler needs it:

       1. Declare the interface, if this class is the first of its kind:
          a pointer, then a record extending `Oberon.ObjectDesc` that declares
          the method fields and no state.  `Done` is NOT among them - it is
          inherited, and writing it again is the one thing forbidden above.
       2. Declare the concrete pointer and then its record, extending the
          interface record, with the class's state and no methods.
       3. Write the destructor: `PROCEDURE DoneSomething (self: Oberon.Object)`,
          beginning with the guard `x := self(Something)`, freeing what the
          object owns, and ending with `DISPOSE(x)`.
       4. Write each method implementation, taking the type its FIELD was
          declared with and guarding down inside.
       5. Write the constructor: `NEW`, set the state, bind every method field
          including `x.Done := DoneSomething`, and answer NIL on failure after
          giving back what was already taken.
       6. Reach it from outside as `Oberon.Done(x)`, or as `x.Done(x)` when the
          caller knows the concrete type.

   HOW THE DESIGN IS CHECKED.  Nothing sweeps these; each was run by hand and
   each prints its own verdict, so a missing verdict line is itself the signal
   - a trap in a `lib/Windows` program is an invisible message box and reaches
   the shell as a successful exit.  `_probe/ObjInh.mod` proves inheritance,
   the two-level guard, assignment to a base variable, and that the base
   variable finds the extension's binding.  `_probe/ObjRoot.mod` proves the
   name-collision question above, the default object, and that an extension is
   destroyed through `Oberon.Done` with no knowledge of the extension.
   `_probe/ObjBound.mod` is expected NOT to compile and records why.

   AND DISPOSE IS NOT ON EVERY TARGET THIS LANGUAGE HAS.  It is missing on
   msp430, stm32cm3, rvm32i and rvm64i, whose runtimes ship no `_dispose`, so
   this module cannot be built for them - and neither can anything that extends
   it, which is the same limit the modules that already need DISPOSE have. *)

TYPE
    Object* = POINTER TO ObjectDesc;
    ObjectDesc* = RECORD
        (* The destructor.  Every extension inherits this field and every
           constructor binds it; a caller reaches it through `Oberon.Done`, or
           directly as `o.Done(o)` on an object it knows is not NIL.  It takes
           `Object` and not the derived type because a procedure variable's
           type has to match its field's exactly - see the manual above. *)
        Done*: PROCEDURE (self: Object)
    END;

(* The destructor of a plain Object: there is nothing in the record but the
   method table, so there is nothing to free but the record.  Declared before
   New because a procedure has to be named before it is used. *)
PROCEDURE DoneObject (self: Object);
BEGIN
    DISPOSE(self)
END DoneObject;

(* A bare object.  Answers a new record with Done bound to the destructor
   above, so a caller that wants an object with no state of its own - or a
   module that extends ObjectDesc and wants to see the binding written out -
   has one to start from. *)
PROCEDURE New* (): Object;
VAR o: Object;
BEGIN
    NEW(o);
    o.Done := DoneObject;
    RETURN o
END New;

(* Destroy any object, through the root type.  NIL is accepted and ignored, so
   a caller whose constructor answers NIL on failure needs no test before this
   call.  An object whose Done was never bound is left alone rather than
   trapping, because a half-built object is exactly the thing a failed
   constructor leaves behind.
   Parameters: o - the object, or NIL. *)
PROCEDURE Done* (o: Object);
BEGIN
    IF (o # NIL) & (o.Done # NIL) THEN
        o.Done(o)
    END
END Done;

END Oberon.
