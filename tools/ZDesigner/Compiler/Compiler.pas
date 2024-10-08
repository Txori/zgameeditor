{Copyright (c) 2021 Ville Krumlinde

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.}

//This unit is the glue between ZExpressions and Zc
//VM code generation
unit Compiler;

{$include zzdc_globalopt.inc}

interface

uses ZClasses,ZExpressions,Classes,uSymTab,SysUtils,Contnrs,ZApplication;

type
  EZcErrorBase = class(Exception)
  public
    Component : TZComponent;
    constructor Create(const M : string); reintroduce;
  end;

  ECodeGenError = class(EZcErrorBase);
  EParseError = class(EZcErrorBase)
  public
    Line,Col : integer;
  end;


procedure Compile(ZApp : TZApplication; ThisC : TZComponent;
  const Ze : TZExpressionPropValue;
  SymTab : TSymbolTable;
  const ReturnType : TZcDataType;
  GlobalNames : Contnrs.TObjectList;
  ExpKind : TExpressionKind);

function CompileEvalExpression(const Expr : string;
  App : TZApplication;
  TargetCode : TZComponentList) : TZcDataType;

var
  CompileDebugString : string;

implementation

uses Zc, Zc_Ops, Vcl.Dialogs, Generics.Collections, Math
  {$if defined(zgeviz) and defined(fpc)}
  ,WideStrings
  {$endif}
  ;


type
  TLabelUse = class
  private
    AdrPtr : PInteger;
    AdrPC : integer;
  end;

  TZCodeLabel = class
  private
    Usage : Contnrs.TObjectList;
    Definition : integer;
    constructor Create;
    destructor Destroy; override;
    function IsDefined : boolean;
  end;

  TAssignLeaveValueStyle = (alvNone,alvPre,alvPost);

  TZCodeGen = class
  private
    Target : TZComponentList;
    Component : TZComponent;
    ZApp : TZApplication;
    SymTab : TSymbolTable;
    Labels : Contnrs.TObjectList;
    CurrentFunction : TZcOpFunctionUserDefined;
    IsLibrary,IsExternalLibrary : boolean;
    BreakLabel,ContinueLabel,ReturnLabel : TZCodeLabel;
    BreakStack,ContinueStack,ReturnStack : TStack<TZCodeLabel>;
    procedure UseLabel(Lbl : TZCodeLabel; Addr : pointer);
    procedure Gen(Op : TZcOp);
    procedure GenJump(Kind : TExpOpJumpKind; Lbl : TZCodeLabel; T : TZcDataTypeKind = zctFloat);
    function NewLabel : TZCodeLabel;
    procedure DefineLabel(Lbl : TZCodeLabel);
    procedure ResolveLabels;
    procedure FallTrue(Op : TZcOp; Lbl : TZCodeLabel);
    procedure FallFalse(Op : TZcOp; Lbl : TZCodeLabel);
    procedure GenValue(Op : TZcOp);
    procedure GenFuncCall(Op : TZcOp; NeedReturnValue : boolean);
    procedure GenAssign(Op: TZcOp; LeaveValue : TAssignLeaveValueStyle);
    procedure GenAddress(Op : TZcOp);
    procedure GenAddToPointer(const Value : integer);
    procedure MakeLiteralOp(const Value: double; Typ: TZcDataType);
    procedure MakeStringLiteralOp(const Value : string);
    procedure SetBreak(L : TZCodeLabel);
    procedure SetContinue(L : TZCodeLabel);
    procedure SetReturn(L : TZCodeLabel);
    procedure RestoreBreak;
    procedure RestoreContinue;
    procedure RestoreReturn;
    procedure GenInvoke(Op: TZcOpInvokeComponent; IsValue: boolean);
    function GenArrayAddress(Op : TZcOp) : TObject;
    procedure PostOptimize;
  public
    procedure GenRoot(StmtList : Classes.TList);
    constructor Create;
    destructor Destroy; override;
  end;

function MakeBinaryOp(Kind : TExpOpBinaryKind; Typ : TZcDataType) : TExpBase;
begin
  case Typ.Kind of
    zctFloat :
      begin
        if Kind in [vbkBinaryOr,vbkBinaryAnd,vbkBinaryXor,vbkBinaryShiftLeft,vbkBinaryShiftRight,vbkMod] then
          raise ECodeGenError.Create('Cannot use this operator on a float-expression');
        Result := TExpOpBinaryFloat.Create(nil,Kind);
      end;
    zctInt,zctByte : Result := TExpOpBinaryInt.Create(nil,Kind);
    zctString :
      begin
        if Kind<>vbkPlus then
          raise ECodeGenError.Create('Cannot use this operator on a string-expression');
        Result := TExpStringConCat.Create(nil);
      end;
    zctMat4 :
      begin
        if Kind<>vbkMul then
          raise ECodeGenError.Create('Cannot use this operator on a mat4-expression');
        Result := TExpMat4FuncCall.Create(nil);
        TExpMat4FuncCall(Result).Kind := fcMatMultiply;
      end
  else
    raise ECodeGenError.Create('Wrong datatype for binaryop');
  end;
end;

function MakeAssignOp(const Typ : TZcDataTypeKind) : TExpBase; overload;
begin
  case Typ of
    zctByte : Result := TExpAssign1.Create(nil);
    zctInt,zctFloat : Result := TExpAssign4.Create(nil);
  else
    Result := TExpAssignPointer.Create(nil);
  end;
end;

function MakeAssignOp(const Typ : TZPropertyType) : TExpBase; overload;
begin
  case Typ of
    zptByte, zptBoolean: Result := TExpAssign1.Create(nil);
    zptString, zptComponentRef, zptPointer: Result := TExpAssignPointer.Create(nil);
  else
    Result := TExpAssign4.Create(nil);
  end;
end;

procedure TZCodeGen.MakeLiteralOp(const Value : double; Typ : TZcDataType);
begin
  case Typ.Kind of
    zctFloat :
      with TExpConstantFloat.Create(Target) do
        Constant := Value;
    zctByte, zctInt :
      //Need to cast from double, otherwise precision problem: assert( StrToInt('$01111111'=17895697) );
      with TExpConstantInt.Create(Target) do
        Constant := Round(Value);
    zctNull : TExpMisc.Create(Target,emLoadNull);
    else
      raise ECodeGenError.Create('Invalid literal: ' + FloatToStr(Value));
  end;
end;

procedure TZCodeGen.MakeStringLiteralOp(const Value : string);
var
  Con : TExpStringConstant;
  Op : TZcop;
begin
  Con := ZApp.AddToConstantPool(Value) as TExpStringConstant;
  Op := MakeOp(zcIdentifier);
  Op.Ref := Con;
  Op := MakeOp(zcSelect,[Op]);
  Op.Id := 'Value';
  GenValue(Op);
end;

function TZCodeGen.GenArrayAddress(Op : TZcOp) : TObject;
//Generates address to element in array
var
  A : TObject;
  I : integer;
begin
  A := Op.Ref;
  if (A is TZcOpVariableBase) then
    A := TZcOpVariableBase(A).Typ.TheArray;
  if (A=nil) or (not (A is TDefineArray)) then
    raise ECodeGenError.Create('Identifier is not an array: ' + Op.Id);
  if Ord((A as TDefineArray).Dimensions)+1<>Op.Children.Count then
    raise ECodeGenError.Create('Wrong nr of array indices: ' + Op.ToString);
  for I := 0 to Op.Children.Count-1 do
    GenValue(Op.Child(I));//Indices
  GenValue((Op as TZcOpArrayAccess).ArrayOp);

  if (Op as TZcOpArrayAccess).IsRawMem then
    with TExpGetRawMemElement.Create(Target) do
      _Type := TZcOpArrayAccess(Op).ArrayOp.GetDataType.Kind
  else
    TExpArrayGetElement.Create(Target);

  Result := A;
end;

//Genererar en op som skapar ett v�rde p� stacken
procedure TZCodeGen.GenValue(Op : TZcOp);

  procedure DoGenBinary(Kind : TExpOpBinaryKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    Target.AddComponent( MakeBinaryOp(Kind,Op.GetDataType) );
  end;

  procedure DoDeref(Op : TZcOp);
  var
    Etyp : TZcIdentifierInfo;
    PTyp : TZPropertyType;
    Kind : TExpMiscKind;
  begin
    Etyp := Op.GetIdentifierInfo;
    if ETyp.Kind=edtField then
    begin
      //todo: save pointersize in app and fail if not expected
      case GetZcTypeSize(ETyp.Field.GetDataType.Kind) of
        1 : Kind := emPtrDeref1;
        SizeOf(Pointer) : Kind := emPtrDerefPointer;
      else
        Kind := emPtrDeref4;
      end;
    end
    else
    begin
      if ETyp.Kind=edtPropIndex then
        Etyp := Op.Children.First.GetIdentifierInfo;

      if Etyp.Kind=edtProperty then
        PTyp := Etyp.Prop.PropertyType
      else if Etyp.Kind=edtModelDefined then
        PTyp := zptComponentRef
      else
        raise ECodeGenError.Create('Failed to deref ' + Op.Id);

      case PTyp of
        zptString,zptComponentRef,zptPointer: Kind := emPtrDerefPointer;
        zptByte,zptBoolean: Kind := emPtrDeref1;
      else
        Kind := emPtrDeref4;
      end;
    end;
    TExpMisc.Create(Target,Kind);
  end;

  procedure DoGenIdentifier;
  var
    L : TExpAccessLocal;
    G : TExpAccessGlobal;
  begin
    if (Op.Ref is TZcOpLocalVar) or (Op.Ref is TZcOpArgumentVar) then
    begin
      //Local variable or argument
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loLoad;
      if (Op.Ref is TZcOpArgumentVar) and (Op.Ref as TZcOpArgumentVar).Typ.IsPointer then
      begin //"ref" argument, need to dereference pointer to get value
        TExpMisc.Create(Target, emPtrDerefPointer);
      end;
    end else if (Op.Ref is TZcOpGlobalVar) then
    begin
      //Global non-managed variable
      G := TExpAccessGlobal.Create(Target);
      G.Offset := (Op.Ref as TZcOpGlobalVar).Offset;
      G.Lib := (Op.Ref as TZcOpGlobalVar).Lib;
      G.Kind := glLoad;
    end else if LowerCase(Op.Id)='currentmodel' then
    begin
      TExpMisc.Create(Target,emLoadCurrentModel)
    end else if Op.Ref is TZComponent then
    begin
      with TExpLoadComponent.Create(Target) do
        Component := Op.Ref as TZComponent;
    end else
    begin
      //Property reference
      GenAddress(Op);
      DoDeref(Op);
    end;
  end;

  procedure DoGenSelect;
  var
    ETyp : TZcIdentifierInfo;
  begin
    ETyp := Op.GetIdentifierInfo;
    case ETyp.Kind of
      edtModelDefined :
        begin
          GenValue(Op.Children.First);
          with TExpLoadModelDefined.Create(Target) do
          begin
            DefinedIndex := ETyp.DefinedIndex;
            DefinedName := ETyp.Component.Name;
            ComponentRef := ETyp.Component; //Set this so "Delete component" in IDE detects reference to the component
          end;
        end
      else
      begin
        GenAddress(Op);
        DoDeref(Op);
      end;
    end;
  end;

  procedure DoGenBoolean;
  //boolexpr "x<5" generates: if(boolexpr) push(1) else push(0)
  var
    LExit,LFalse : TZCodeLabel;
  begin
    LExit := NewLabel;
    LFalse := NewLabel;
    FallTrue(Op,LFalse);

    //Gen "true" body
    MakeLiteralOp(1, Op.GetDataType);
    //jump to exit
    GenJump(jsJumpAlways,LExit);

    //Gen "false"
    DefineLabel(LFalse);
    MakeLiteralOp(0, Op.GetDataType);

    DefineLabel(LExit);
  end;

  procedure DoGenArrayRead;
  var
    A : TObject;
  begin
    A := GenArrayAddress(Op);
    case TDefineArray(A)._Type.Kind of
      zctByte :
        TExpMisc.Create(Target, emPtrDeref1);
      zctString,zctModel,zctXptr,zctClass :
        TExpMisc.Create(Target, emPtrDerefPointer);
      else
        if TDefineArray(A)._Type.Kind in [zctMat4,zctVec2,zctVec3,zctVec4] then
        begin
          //Do not deref, pointer points to list of values
        end else
          TExpMisc.Create(Target, emPtrDeref4);
    end;
  end;

  procedure DoGenConvert;
  var
    C : TExpConvert;
    COp : TZcOpConvert;
    Kind : TExpConvertKind;
    FromOp : TZcOp;
    IdInfo : TZcIdentifierInfo;
    IsValue : boolean;
  begin
    COp := Op As TZcOpConvert;
    Kind := TExpConvertKind(99);
    FromOp := Cop.Child(0);
    IsValue := True;

    if (Cop.ToType.Kind in [zctByte,zctInt,zctFloat]) and (Cop.ToType.Kind=FromOp.GetDataType.Kind) then
    begin //Superflous conversions can exist after inlining
      GenValue(Op.Child(0));
      Exit;
    end;

    case FromOp.GetDataType.Kind of
      zctFloat :
        case Cop.ToType.Kind of
          zctByte, zctInt: Kind := eckFloatToInt;
          zctXptr :
            begin
              GenAddress(Op.Child(0));
              Exit;
            end;
          zctVec3 : //convert component properties to vec3
            begin
              if (FromOp.Kind=zcSelect) then
              begin
                IdInfo := FromOp.GetIdentifierInfo;
                if (IdInfo.Kind=edtProperty) and (IdInfo.Prop.PropertyType in [zptVector3f]) then
                begin
                  Kind := eckPropToVec3;
                  IsValue := False;
                end;
              end;
            end;
          zctVec4 :
            begin
              if (FromOp.Kind=zcSelect) then
              begin
                IdInfo := FromOp.GetIdentifierInfo;
                if (IdInfo.Kind=edtProperty) and (IdInfo.Prop.PropertyType in [zptColorf]) then
                begin
                  Kind := eckPropToVec4;
                  IsValue := False;
                end;
              end;
            end;
        end;
      zctByte, zctInt :
        case Cop.ToType.Kind of
          zctFloat: Kind := eckIntToFloat;
          zctXptr :
            begin
              GenAddress(Op.Child(0));
              Exit;
            end;
        end;
      zctVoid :
        begin
          if (Cop.ToType.Kind=zctXptr) then
          begin
            IdInfo := FromOp.GetIdentifierInfo;
            if (IdInfo.Kind=edtProperty) and (idInfo.Prop.PropertyType=zptBinary) then
            begin
              Kind := eckBinaryToXptr;
              IsValue := False;
            end;
          end;
        end;
      zctReference, zctMat4,zctVec2,zctVec3,zctVec4,zctArray :
        case Cop.ToType.Kind of
          zctXptr :
            begin
              if Assigned(FromOp.Ref) and (FromOp.Ref is TDefineArray) then
                Kind := eckArrayToXptr
              else if FromOp.GetDataType.Kind in [zctMat4,zctVec2,zctVec3,zctVec4,zctArray] then
                Kind := eckArrayToXptr;
            end;
        else
          if Cop.ToType.Kind=FromOp.GetDataType.Kind then
          begin
            //This is vec3[0] to vec3 ref conversion
            GenValue(Op.Child(0));
            with TExpArrayUtil.Create(Target) do
            begin
              Kind := auRawMemToArray;
              _Type := Cop.ToType.Kind;
            end;
            Exit;
          end;
        end;
      zctClass :
        if Cop.ToType.Kind=zctXptr then
        begin
          GenValue(Op.Child(0));
          TExpMisc.Create(Target, emGetUserClass);
          Exit;
        end;
    end;
    if Ord(Kind)=99 then
      raise ECodeGenError.Create('Invalid conversion: ' + Op.ToString);
    if IsValue then
      GenValue(Op.Child(0))
    else
      GenAddress(Op.Child(0));
    C := TExpConvert.Create(Target);
    C.Kind := Kind;
  end;

  procedure DoLiteral;
  begin
    if Op.GetDataType.Kind=zctString then
      MakeStringLiteralOp((Op as TZcOpLiteral).StringValue)
    else
      MakeLiteralOp((Op as TZcOpLiteral).Value, Op.GetDataType);
  end;

  procedure DoGenConditional;
  //expr ? value1 : value2;
  var
    LExit,LFalse : TZCodeLabel;
  begin
    LFalse := NewLabel;
    LExit := NewLabel;

    FallTrue(Op.Child(0),LFalse);

    GenValue(Op.Child(1));
    GenJump(jsJumpAlways,LExit);

    DefineLabel(LFalse);
    GenValue(Op.Child(2));
    DefineLabel(LExit);
  end;

  procedure DoGenNew;
  var
    NewC : TExpNewClassInstance;
  begin
    NewC := TExpNewClassInstance.Create(Target);
    NewC.TheClass := (Op.Ref as TZcOpClass).RuntimeClass;
  end;

  procedure DoGenInitArray(Op : TZcOp);
  var
    Loc : TZcOpVariableBase;
  begin
    Loc := Op.Ref as TZcOpVariableBase;
    with TExpInitArray.Create(Target) do
    begin
      Dimensions := TDefineArray(Loc.Typ.TheArray).Dimensions;
      _Type := TDefineArray(Loc.Typ.TheArray)._Type.Kind;
      Size1 := TDefineArray(Loc.Typ.TheArray).SizeDim1;
      Size2 := TDefineArray(Loc.Typ.TheArray).SizeDim2;
      Size3 := TDefineArray(Loc.Typ.TheArray).SizeDim3;
    end;
  end;

begin
  case Op.Kind of
    zcNop : ;
    zcMul : DoGenBinary(vbkMul);
    zcDiv : DoGenBinary(vbkDiv);
    zcPlus : DoGenBinary(vbkPlus);
    zcMinus : DoGenBinary(vbkMinus);
    zcBinaryOr : DoGenBinary(vbkBinaryOr);
    zcBinaryAnd : DoGenBinary(vbkBinaryAnd);
    zcBinaryXor : DoGenBinary(vbkBinaryXor);
    zcBinaryShiftL : DoGenBinary(vbkBinaryShiftLeft);
    zcBinaryShiftR : DoGenBinary(vbkBinaryShiftRight);
    zcConstLiteral : DoLiteral;
    zcIdentifier : DoGenIdentifier;
    zcFuncCall,zcMethodCall : GenFuncCall(Op,True);
    zcCompLT,zcCompGT,zcCompEQ,
    zcCompNE,zcCompLE,zcCompGE,
    zcAnd, zcOr : DoGenBoolean;
    zcArrayAccess : DoGenArrayRead;
    zcConvert : DoGenConvert;
    zcAssign,zcPreInc,zcPreDec : GenAssign(Op,alvPost);
    zcPostInc,zcPostDec : GenAssign(Op,alvPre);
    zcConditional : DoGenConditional;
    zcSelect : DoGenSelect;
    zcReinterpretCast : GenValue(Op.Child(0));
    zcMod : DoGenBinary(vbkMod);
    zcInvokeComponent : GenInvoke(Op as TZcOpInvokeComponent, True);
    zcInlineBlock : Gen(Op);
    zcBinaryNot :
      begin
        GenValue(Op.Child(0));
        TExpMisc.Create(Target,emBinaryNot);
      end;
    zcNot :
      begin
        GenValue(Op.Child(0));
        TExpMisc.Create(Target,emNot);
      end;
    zcNew : DoGenNew;
    zcInitArray : DoGenInitArray(Op);
  else
    //Gen(Op); //Any op can occur in a value block because of inlining
    raise ECodeGenError.Create('Unsupported operator for value expression: ' + IntToStr(ord(Op.Kind)) );
  end;
end;

procedure TZCodeGen.GenAddToPointer(const Value: integer);
var
  Cnt : TExpConstantInt;
begin
  if Value=0 then
    Exit;

  if (Target.Last is TExpAddToPointer) then
  begin
    //Accumulate to previous add
    if (Target[ Target.Count-2 ] is TExpConstantInt) then
    begin
      Cnt := Target[ Target.Count-2 ] as TExpConstantInt;
      Inc(Cnt.Constant,Value);
      Exit;
    end;
  end;

  //Create new add
  Cnt := TExpConstantInt.Create(Target);
  Cnt.Constant := Value;
  TExpAddToPointer.Create(Target);
end;

procedure TZCodeGen.GenAddress(Op: TZcOp);

  procedure DoGenIdent;
  var
    L : TExpAccessLocal;
    G : TExpAccessGlobal;
  begin
    if Assigned(Op.Ref) and (Op.Ref is TZcOpArgumentVar) and (Op.Ref as TZcOpArgumentVar).Typ.IsPointer then
    begin
      //The value of a ref-argument is the address to the referenced variable
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loLoad;
    end else if Assigned(Op.Ref) and ((Op.Ref is TZcOpLocalVar) or (Op.Ref is TZcOpArgumentVar)) then
    begin //Get the address to a local variable
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loGetAddress;
    end else if Assigned(Op.Ref) and (Op.Ref is TZcOpGlobalVar) then
    begin
      //Address of global non-managed variable
      G := TExpAccessGlobal.Create(Target);
      G.Offset := (Op.Ref as TZcOpGlobalVar).Offset;
      G.Lib := (Op.Ref as TZcOpGlobalVar).Lib;
      G.Kind := glGetAddress;
    end
    else
      raise ECodeGenError.Create('Invalid address expression: ' + Op.Id);
  end;

  procedure DoGenSelect;
  var
    ETyp : TZcIdentifierInfo;
  begin
    ETyp := Op.GetIdentifierInfo;
    case ETyp.Kind of
      edtProperty :
        begin
          GenValue(Op.Children.First);
          if Assigned(ETyp.Prop.GlobalData) then
          begin //Audiomixer has global data
            with TExpConstantInt.Create(Target) do
              Constant := ETyp.Prop.PropId;
            TExpMisc.Create(Target,emGetGlobalDataProp);
          end else
          begin
            {$ifdef zgeviz}
            with TExpConstantInt.Create(Target) do
              Constant := ETyp.Prop.Offset;
            {$else}
            //For binaries, the offset needs to be runtime (offsets are different on Android etc)
            with TExpLoadPropOffset.Create(Target) do
              PropId := ETyp.Prop.PropId;
            {$endif}
            TExpAddToPointer.Create(Target);
          end;
        end;
      edtPropIndex :
        begin
          GenAddress(Op.Children.First);
          GenAddToPointer(ETyp.PropIndex * 4);
        end;
      edtField :
        begin
          GenValue(Op.Children.First);
          TExpMisc.Create(Target,emGetUserClass);
          GenAddToPointer(ETyp.Field.ByteOffset);
        end
      else
        raise ECodeGenError.Create('Invalid datatype for select: ' + Op.Id);
    end;
  end;

begin
  case Op.Kind of
    zcIdentifier : DoGenIdent;
    zcSelect : DoGenSelect;
    zcArrayAccess : GenArrayAddress(Op);
  else
    raise ECodeGenError.Create('Cannot get address of expression: ' + Op.ToString);
  end;
end;

procedure TZCodeGen.GenAssign(Op : TZcOp; LeaveValue : TAssignLeaveValueStyle);
//LeaveValue : Optionally leave a value of the assignment on stack.
//  alvPre: Leave the value prior to the assignment (i++)
//  alvPost: Leave the value after the assignment (++i)
var
  A : TObject;
  LeftOp,RightOp : TZcOp;
  L : TExpAccessLocal;
  G : TExpAccessGlobal;
  Etyp : TZcIdentifierInfo;
  Prop : TZProperty;
begin
  //Left-hand side of the assignment
  LeftOp := Op.Child(0);
  RightOp := Op.Child(1);

  if LeaveValue=alvPre then
    GenValue(LeftOp);

  if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and (LeftOp.Ref is TZcOpArgumentVar) and
    (LeftOp.Ref as TZcOpArgumentVar).Typ.IsPointer  then
  begin
    //Local "ref" argument
    GenAddress(LeftOp);
    GenValue(RightOp);
    Target.AddComponent( MakeAssignOp( LeftOp.GetDataType.Kind ) );
    if LeaveValue=alvPost then
      GenValue(LeftOp);
  end else if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and
    (LeftOp.Ref is TZcOpArgumentVar) and (LeftOp.GetDataType.Kind in [zctVec3,zctVec4])  then
  begin
    //vec3/4 arguments (pixel/mesh expressions)
    //make sure that expression such as pixel=vector3(..) actually assigns to pixel data
    //so make assignment by value instead of by reference
    GenValue(RightOp);
    GenValue(LeftOp);
    with TExpArrayUtil.Create(Target) do
      Kind := auArrayToArray;
  end else if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and
    ((LeftOp.Ref is TZcOpLocalVar) or (LeftOp.Ref is TZcOpArgumentVar))  then
  begin
    //Local variable or argument
    GenValue(RightOp);
    if LeaveValue=alvPost then
      TExpMisc.Create(Target, emDup);
    L := TExpAccessLocal.Create(Target);
    L.Index := (LeftOp.Ref as TZcOpVariableBase).Ordinal;
    L.Kind := loStore;
  end else if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and
    (LeftOp.Ref is TZcOpGlobalVar)  then
  begin
    //Global non-managed variable
    GenValue(RightOp);
    if LeaveValue=alvPost then
      TExpMisc.Create(Target, emDup);
    G := TExpAccessGlobal.Create(Target);
    G.Offset := (LeftOp.Ref as TZcOpGlobalVar).Offset;
    G.Lib := (LeftOp.Ref as TZcOpGlobalVar).Lib;
    G.Kind := glStore;
  end else if LeftOp.Kind=zcSelect then
  begin
    Etyp := LeftOp.GetIdentifierInfo;
    if Etyp.Kind=edtField then
    begin
      GenAddress(LeftOp);
      GenValue(RightOp);
      Target.AddComponent( MakeAssignOp( LeftOp.GetDataType.Kind ) );
    end else
    begin
      case Etyp.Kind of
        edtProperty : Prop := Etyp.Prop;
        edtPropIndex :
          begin
            Etyp := LeftOp.Children.First.GetIdentifierInfo;
            Assert(Etyp.Kind=edtProperty);
            Prop := Etyp.Prop;
          end
      else
        raise ECodeGenError.Create('Invalid type: ' + LeftOp.Id);
      end;
      if Prop.IsReadOnly then
        raise ECodeGenError.Create('Cannot assign readonly property identifier: ' + LeftOp.Id);
      if (Prop.PropertyType=zptString) and (not Prop.IsManagedTarget) then
        raise ECodeGenError.Create('Cannot assign readonly property identifier: ' + LeftOp.Id);

      if Assigned(Prop.NotifyWhenChanged) then
      begin //This property should notify when assigned, generate notify call
        GenValue(RightOp);
        GenValue(LeftOp.Children.First);
        with TExpConstantInt.Create(Target) do
          Constant := Prop.PropId;
        TExpMisc.Create(Target,emNotifyPropChanged);
      end else
      begin
        GenAddress(LeftOp);
        GenValue(RightOp);
        Target.AddComponent( MakeAssignOp(Prop.PropertyType) );
      end;
    end;

   if LeaveValue=alvPost then
     GenValue(LeftOp);
  end else if LeftOp.Kind=zcArrayAccess then
  begin
    A := GenArrayAddress(LeftOp);
    GenValue(Op.Child(1));
    if LeftOp.GetDataType.Kind in [zctMat4,zctVec2,zctVec3,zctVec4] then
    begin //These types are copied by value into arrays (to allow VBO arrays with vec3 etc)
      with TExpArrayUtil.Create(Target) do
        Kind := auArrayToRawMem;
      if LeaveValue=alvPost then
        raise ECodeGenError.Create('Assign syntax not supported for this kind of variable');
    end
    else
    begin
      Target.AddComponent( MakeAssignOp((A as TDefineArray)._Type.Kind ) );
      if LeaveValue=alvPost then
        GenValue(LeftOp);
    end;
  end else
    raise ECodeGenError.Create('Assignment destination must be variable or array: ' + Op.Child(0).Id);

end;

procedure TZCodeGen.GenInvoke(Op : TZcOpInvokeComponent; IsValue : boolean);
var
  Inv : TExpInvokeComponent;
  Ci : TZComponentInfo;
  Arg : TZcOp;
  Prop : TZProperty;
begin
  Ci := ComponentManager.GetInfoFromName(Op.Id);
  if (not IsValue) and (not Ci.ZClass.InheritsFrom(TCommand)) then
    raise ECodeGenError.Create('Class must inherit TCommand: ' + Op.Id);
  for Arg in Op.Children do
  begin
    Prop := Ci.GetProperties.GetByName(Arg.Id);
    Assert(Prop<>nil);
    GenValue(Arg.Children.First);
    with TExpConstantInt.Create(Target) do
      Constant := Prop.PropId;
  end;
  Inv := TExpInvokeComponent.Create(Target);
  Inv.InvokeClassId := integer( Ci.ClassId );
  Inv.InvokeArgCount := Op.Children.Count;
  Inv.IsValue := IsValue;
end;

procedure TZCodeGen.Gen(Op : TZcOp);
var
  I : integer;

  procedure DoGenIf;
  var
    LExit,LElse : TZCodeLabel;
    HasElse : boolean;
  begin
    HasElse := Assigned(Op.Child(2));
    LExit := NewLabel;
    if HasElse then
    begin
      LElse := NewLabel;
      FallTrue(Op.Child(0),LElse);
    end
    else
    begin
      LElse := nil;
      FallTrue(Op.Child(0),LExit);
    end;
    //Gen "then" body
    Gen(Op.Child(1));
    if HasElse then
    begin //ELSE
      //Write jump past else-body for then-body
      GenJump(jsJumpAlways,LExit);
      DefineLabel(LElse);
      //Gen else-body
      Gen(Op.Child(2));
    end;
    DefineLabel(LExit);
  end;

  procedure DoGenForLoop;
  var
    LExit,LLoop,LContinue : TZCodeLabel;
  begin
    //Children: [ForInitOp,ForCondOp,ForIncOp,ForBodyOp]
    if Assigned(Op.Child(0)) then
      Gen(Op.Child(0));

    LExit := NewLabel;
    LLoop := NewLabel;
    LContinue := NewLabel;
    DefineLabel(LLoop);

    SetBreak(LExit);
    SetContinue(LContinue);

    if Assigned(Op.Child(1)) then
      FallTrue(Op.Child(1),LExit);

    if Assigned(Op.Child(3)) then
      Gen(Op.Child(3));

    DefineLabel(LContinue);
    if Assigned(Op.Child(2)) then
      Gen(Op.Child(2));
    GenJump(jsJumpAlways,LLoop);

    DefineLabel(LExit);
    RestoreBreak;
    RestoreContinue;
  end;

  procedure DoWhile(PreTest : boolean);
  var
    LExit,LLoop : TZCodeLabel;
  begin
    //Children: [WhileCondOp,WhileBodyOp]
    LExit := NewLabel;

    LLoop := NewLabel;
    DefineLabel(LLoop);

    SetBreak(LExit);
    SetContinue(LLoop);

    if PreTest then
    begin
      if Assigned(Op.Child(0)) then
        FallTrue(Op.Child(0),LExit);

      if Assigned(Op.Child(1)) then
        Gen(Op.Child(1));
      GenJump(jsJumpAlways,LLoop);
    end else
    begin //do while
      if Assigned(Op.Child(1)) then
        Gen(Op.Child(1));
      if Assigned(Op.Child(0)) then
        FallFalse(Op.Child(0),LLoop);
    end;

    DefineLabel(LExit);
    RestoreBreak;
    RestoreContinue;
  end;

  procedure DoGenReturn;
  var
    L : TExpAccessLocal;
  begin
    //"return x", generate value + jump to exit
    if CurrentFunction.ReturnType.Kind<>zctVoid then
    begin
      GenValue(Op.Child(0));
      //Store return value in local0
      L := TExpAccessLocal.Create(Target);
      L.Index := 0;
      L.Kind := loStore;
    end;
    GenJump(jsJumpAlways,ReturnLabel);
  end;

  procedure DoGenInlineReturn;
  begin
    //"return x", generate value + jump to exit
    if Op.Children.Count>0 then
      GenValue(Op.Child(0));
    GenJump(jsJumpAlways,ReturnLabel);
  end;

  procedure DoGenFunction(Func : TZcOpFunctionUserDefined);
  var
    I : integer;
    Frame : TExpStackFrame;
    Ret : TExpReturn;
    LReturn:TZCodeLabel;
  begin
    if (Func.Id='') and (Func.Statements.Count=0) then
      Exit; //Don't generate code for empty nameless function (such as Repeat.WhileExp)

    LReturn := NewLabel;
    SetReturn(LReturn);

    if IsLibrary then
    begin
      Func.Lib := Component as TZLibrary;
      Func.LibIndex := Target.Count;
    end;

    if (mdVirtual in Func.Modifiers) or (mdOverride in Func.Modifiers) then
    begin
      PIntegerArray(Func.MemberOf.RuntimeClass.Vmt.Data)^[ Func.VmtIndex ] := Target.Count;
    end;

    if IsExternalLibrary and (Func.Id<>'') and (Func.Id<>'__f') then
    begin
      Func.IsExternal := True;
      if Func.Statements.Count>0 then
        raise ECodeGenError.Create('External functions definitions can not have a body: ' + Func.Id );
      Func.ExtLib := Component as TZExternalLibrary;
    end;
    Self.CurrentFunction := Func;
    if Func.NeedFrame then
    begin
      Frame := TExpStackFrame.Create(Target);
      Frame.Size := Func.GetStackSize;
    end;

    for I := 0 to Func.Statements.Count - 1 do
    begin
      Gen(Func.Statements[I] as TZcOp);
    end;

    DefineLabel(LReturn);
    RestoreReturn;

    //Todo: Skip return if IsExternalLib and PropName='Source'
    Ret := TExpReturn.Create(Target);
    Ret.HasFrame := Func.NeedFrame;
    Ret.HasReturnValue := Func.ReturnType.Kind<>zctVoid;
    Ret.Arguments := Func.Arguments.Count;
    {$ifdef CALLSTACK}
    if IsLibrary then
    begin
      Ret.FunctionName := Func.Id;
      if Assigned(Func.MemberOf) then
        Ret.FunctionName := Func.MemberOf.Id + '.' + Ret.FunctionName;
    end
    else
      Ret.FunctionName := string(Component.GetDisplayName);
    {$endif}
    if IsLibrary then
      Ret.Lib := Component as TZLibrary;
  end;

  procedure DoGenClass(Cls : TZcOpClass);
  var
    Func : TZcOpFunctionUserDefined;
  begin
    for Func in Cls.Methods do
      DoGenFunction(Func);
    Cls.RuntimeClass.DefinedInLib := Component as TZLibrary;
    if Cls.Initializer.Statements.Count>0 then
    begin
      Cls.RuntimeClass.InitializerIndex := Target.Count;
      DoGenFunction(Cls.Initializer);
    end else
      Cls.RuntimeClass.InitializerIndex := -1;
  end;

  procedure DoGenSwitch(Op : TZcOpSwitch);
  var
    I,J,CaseBlockCount : integer;
    CaseLabels : array of TZCodeLabel;
    CaseType : TZcDataType;
    LExit,LDefault : TZCodeLabel;
    CaseOp,StatOp : TZcOp;

    Jt : TExpSwitchTable;
    Value,MinValue,MaxValue,CaseCount,JumpCount : integer;
    UseJumpTable,CaseIsConstant : boolean;
  begin
    //todo: verify no duplicate values
    CaseBlockCount := Op.CaseOps.Count; //nr of blocks of code
    CaseType := Op.ValueOp.GetDataType;
    SetLength(CaseLabels,CaseBlockCount);
    LExit := NewLabel;
    SetBreak(LExit);
    LDefault := nil;

    UseJumpTable := False;
    CaseCount := 0; //actual total nr of "case", including those that map to same label
    MinValue := High(Integer);
    MaxValue := Low(Integer);
    if CaseType.Kind in [zctInt,zctByte] then
    begin
      CaseIsConstant := True;
      for I := 0 to CaseBlockCount-1 do
      begin
        CaseOp := Op.CaseOps[I];
        for J := 0 to CaseOp.Children.Count - 1 do
        begin
          if Assigned(CaseOp.Child(J)) then
          begin
            if not (CaseOp.Child(J) is TZcOpLiteral) then
            begin
              CaseIsConstant := False; //case expression is not constant
              Break;
            end;
            Value := Round((CaseOp.Child(J) as TZcOpLiteral).Value);
            MinValue := Min(MinValue,Value);
            MaxValue := Max(MaxValue,Value);
            Inc(CaseCount);
          end;
        end;
      end;
      UseJumpTable := CaseIsConstant and (CaseCount>3) and (CaseCount > ((MaxValue-MinValue) div 2));
    end;

    if (not UseJumpTable) then
    begin //Gen as a series of "if" statements
      //Generate jumps
      for I := 0 to CaseBlockCount-1 do
      begin
        CaseLabels[I] := NewLabel;
        CaseOp := Op.CaseOps[I];
        for J := 0 to CaseOp.Children.Count - 1 do
        begin
          if CaseOp.Child(J)=nil then
          begin
            LDefault := CaseLabels[I];
          end else
          begin
            GenValue(Op.ValueOp);
            GenValue(CaseOp.Child(J));
            GenJump(jsJumpEQ,CaseLabels[I],CaseType.Kind);
          end;
        end;
      end;
      if LDefault<>nil then
        GenJump(jsJumpAlways,LDefault,CaseType.Kind)
      else
        GenJump(jsJumpAlways,LExit,CaseType.Kind);
    end else
    begin //Gen using a jumptable
      GenValue(Op.ValueOp);

      JumpCount := (MaxValue-MinValue)+1;

      Jt := TExpSwitchTable.Create(Target);
      Jt.Jumps.Size := JumpCount*4;
      Jt.LowBound := MinValue;
      Jt.HighBound := MaxValue;
      GetMem(Jt.Jumps.Data,Jt.Jumps.Size);
      FillChar(Jt.Jumps.Data^,Jt.Jumps.Size,0);

      for I := 0 to CaseBlockCount-1 do
      begin
        CaseLabels[I] := NewLabel;
        CaseOp := Op.CaseOps[I];
        for J := 0 to CaseOp.Children.Count - 1 do
        begin
          if Assigned(CaseOp.Child(J)) then
          begin
            Value := Round((CaseOp.Child(J) as TZcOpLiteral).Value);
            UseLabel(CaseLabels[I],@PIntegerArray(Jt.Jumps.Data)^[Value - MinValue]);
            PIntegerArray(Jt.Jumps.Data)^[Value - MinValue] := 1; //signal that jump is used
          end else
            LDefault := CaseLabels[I];
        end;
      end;

      for I := 0 to JumpCount-1 do
      begin //assign unused slots (gaps) to default/exit
        if PIntegerArray(Jt.Jumps.Data)^[I]=0 then
        begin
          if Assigned(LDefault) then
            UseLabel(LDefault,@PIntegerArray(Jt.Jumps.Data)^[I])
          else
            UseLabel(LExit,@PIntegerArray(Jt.Jumps.Data)^[I])
        end;
      end;

      if Assigned(LDefault) then
        UseLabel(LDefault,@Jt.DefaultOrExit)
      else
        UseLabel(LExit,@Jt.DefaultOrExit)
    end;

    //Generate statements
    for I := 0 to CaseBlockCount-1 do
    begin
      DefineLabel(CaseLabels[I]);
      StatOp := Op.StatementsOps[I];
      for J := 0 to StatOp.Children.Count - 1 do
        Gen( StatOp.Child(J) );
    end;

    DefineLabel(LExit);
    RestoreBreak;
  end;

  procedure DoGenInlineBlock(Op : TZcOp);
  var
    LReturn : TZCodeLabel;
    I : integer;
  begin
    LReturn := NewLabel;
    SetReturn(LReturn);

    for I := 0 to Op.Children.Count-1 do
      Gen(Op.Children[I]);

    DefineLabel(LReturn);
    RestoreReturn;
  end;

begin
  case Op.Kind of
    zcAssign,zcPreInc,zcPreDec,zcPostDec,zcPostInc : GenAssign(Op,alvNone);
    zcIf : DoGenIf;
    zcNop : ;
    zcBlock :
      for I := 0 to Op.Children.Count-1 do
        Gen(Op.Child(I));
    zcReturn : DoGenReturn;
    zcFuncCall,zcMethodCall : GenFuncCall(Op,False);
    zcFunction : DoGenFunction(Op as TZcOpFunctionUserDefined);
    zcForLoop : DoGenForLoop;
    zcWhile : DoWhile(True);
    zcDoWhile : DoWhile(False);
    zcBreak :
      if Assigned(Self.BreakLabel) then
        GenJump(jsJumpAlways,Self.BreakLabel)
      else
        raise ECodeGenError.Create('Break can only be used in loops');
    zcContinue :
      if Assigned(Self.ContinueLabel) then
        GenJump(jsJumpAlways,Self.ContinueLabel)
      else
        raise ECodeGenError.Create('Continue can only be used in loops');
    zcSwitch : DoGenSwitch(Op as TZcOpSwitch);
    zcInvokeComponent : GenInvoke(Op as TZcOpInvokeComponent, False);
    zcInlineBlock : DoGenInlineBlock(Op);
    zcInlineReturn : DoGenInlineReturn;
    zcClass : DoGenClass(Op as TZcOpClass);
  else
    //GenValue(Op); //Value expressions (return values) can appear because of inlining
    raise ECodeGenError.Create('Unsupported operator: ' + IntToStr(ord(Op.Kind)) );
  end;
end;

destructor TZCodeGen.Destroy;
begin
  Labels.Free;
  BreakStack.Free;
  ContinueStack.Free;
  ReturnStack.Free;
  inherited;
end;

constructor TZCodeGen.Create;
begin
  Labels := Contnrs.TObjectList.Create;
  BreakStack := TStack<TZCodeLabel>.Create;
  ContinueStack := TStack<TZCodeLabel>.Create;
  ReturnStack := TStack<TZCodeLabel>.Create;
end;

procedure TZCodeGen.DefineLabel(Lbl: TZCodeLabel);
begin
  if Lbl.IsDefined then
    raise ECodeGenError.Create('Label already defined');
  Lbl.Definition := Target.Count;
end;

function TZCodeGen.NewLabel: TZCodeLabel;
begin
  Result := TZCodeLabel.Create;
  Labels.Add(Result);
end;

procedure TZCodeGen.GenJump(Kind: TExpOpJumpKind; Lbl: TZCodeLabel; T : TZcDataTypeKind = zctFloat);
var
  Op : TExpJump;
begin
  Op := TExpJump.Create(Target);
  Op.Kind := Kind;
  case T of
    zctFloat: Op._Type := jutFloat;
    zctInt,zctByte: Op._Type := jutInt;
    zctXptr,zctNull,zctModel,zctReference,zctClass : Op._Type := jutPointer;
    zctString:
      begin
        Op._Type := jutString;
        if not (Kind in [jsJumpNE,jsJumpEQ,jsJumpAlways]) then
          raise ECodeGenError.Create('Invalid string comparison');
      end
  else
    raise ECodeGenError.Create('Invalid datatype for jump');
  end;
  UseLabel(Lbl,@Op.Destination);
end;

procedure TZCodeGen.GenRoot(StmtList: Classes.TList);
var
  I : integer;
  LReturn : TZCodeLabel;
begin
  IsLibrary := Component is TZLibrary;
  IsExternalLibrary := Component is TZExternalLibrary;

  LReturn:=nil;
  if (not IsLibrary) and (not IsExternalLibrary) then
  begin //For ZExpression, define label for "return"
    LReturn := NewLabel;
    SetReturn(LReturn);
  end;

  for I := 0 to StmtList.Count-1 do
    Gen(StmtList[I]);

  if Assigned(LReturn) then
  begin
    DefineLabel(LReturn);
    RestoreReturn;
  end;

  ResolveLabels;
  PostOptimize;
end;

procedure TZCodeGen.ResolveLabels;
var
  I,J,Adr : integer;
  Lbl : TZCodeLabel;
  U : TLabelUse;
begin
  for I := 0 to Labels.Count-1 do
  begin
    Lbl := TZCodeLabel(Labels[I]);
    if Lbl.Definition=-1 then
      raise ECodeGenError.Create('Label with missing definition');
    for J := 0 to Lbl.Usage.Count-1 do
    begin
      U := TLabelUse(Lbl.Usage[J]);
      Adr := Lbl.Definition - U.AdrPC - 1;
      U.AdrPtr^ := Adr;
    end;
  end;
end;

procedure TZCodeGen.PostOptimize;
var
  I : integer;
  O : TZComponent;
begin
  for I := 0 to Target.Count-1 do
  begin
    O := TZComponent(Target[I]);
    if (O is TExpJump) and (TExpJump(O).Kind=jsJumpAlways)
    then
    begin
      if TExpJump(O).Destination=0 then
      begin //Replace jump0 with nops
        O.OwnerList:=nil;
        Target[I].Free;
        Target[I] := TExpMisc.Create(nil,emNop);
        TZComponent(Target[I]).OwnerList := Target;
      end else
      begin //Replace jump to jump, with final jump
        while True do
        begin
          if (Target[I+TExpJump(O).Destination+1] is TExpJump) and
          (TExpJump(Target[I+TExpJump(O).Destination+1]).Kind=jsJumpAlways) and
          (Target[I+TExpJump(O).Destination+1]<>O) //Must allow infinite loop
          then
          begin
            Inc(TExpJump(O).Destination, TExpJump(Target[I+TExpJump(O).Destination+1]).Destination+1);
          end
          else
            Break;
        end;
      end;
    end;
  end;
end;

procedure TZCodeGen.RestoreBreak;
begin
  BreakLabel := BreakStack.Pop;
end;

procedure TZCodeGen.RestoreContinue;
begin
  ContinueLabel := ContinueStack.Pop;
end;

procedure TZCodeGen.RestoreReturn;
begin
  ReturnLabel := ReturnStack.Pop;
end;

procedure TZCodeGen.SetBreak(L: TZCodeLabel);
begin
  BreakStack.Push(Self.BreakLabel);
  Self.BreakLabel := L;
end;

procedure TZCodeGen.SetContinue(L: TZCodeLabel);
begin
  ContinueStack.Push(Self.ContinueLabel);
  Self.ContinueLabel := L;
end;

procedure TZCodeGen.SetReturn(L: TZCodeLabel);
begin
  ReturnStack.Push(Self.ReturnLabel);
  Self.ReturnLabel := L;
end;

procedure TZCodeGen.UseLabel(Lbl: TZCodeLabel; Addr: pointer);
var
  U : TLabelUse;
begin
  U := TLabelUse.Create;
  U.AdrPC := Target.Count-1;
  U.AdrPtr := Addr;
  Lbl.Usage.Add(U);
end;

//Fall igenom om false, annars hoppa till Lbl
procedure TZCodeGen.FallFalse(Op: TZcOp; Lbl: TZCodeLabel);

  procedure DoGenComp(Kind : TExpOpJumpKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    GenJump(Kind,Lbl,Op.Child(0).GetDataType.Kind);
  end;

  procedure DoGenAnd;
  var
    LAnd : TZCodeLabel;
  begin
    LAnd := NewLabel;
    FallTrue(Op.Child(0),LAnd);
    FallFalse(Op.Child(1),Lbl);
    DefineLabel(LAnd);
  end;

  procedure DoGenOr;
  begin
    FallFalse(Op.Child(0),Lbl);
    FallFalse(Op.Child(1),Lbl);
  end;

  procedure DoGenValue;
  begin
    //if(1) blir: value,0, compare and jump
    if (Op.Kind=zcConstLiteral) and (TZcOpLiteral(Op).Typ.Kind in [zctInt,zctByte]) then
    begin
      if TZcOpLiteral(Op).Value<>0 then
        GenJump(jsJumpAlways,Lbl, Op.GetDataType.Kind);
    end else
    begin
      GenValue(Op);
      MakeLiteralOp(0, Op.GetDataType);
      GenJump(jsJumpNE,Lbl, Op.GetDataType.Kind);
    end;
  end;

begin
  case Op.Kind of
    zcCompLT : DoGenComp(jsJumpLT);
    zcCompGT : DoGenComp(jsJumpGT);
    zcCompEQ : DoGenComp(jsJumpEQ);
    zcCompNE : DoGenComp(jsJumpNE);
    zcCompLE : DoGenComp(jsJumpLE);
    zcCompGE : DoGenComp(jsJumpGE);
    zcAnd : DoGenAnd;
    zcOr : DoGenOr;
    zcNot : FallTrue(Op.Child(0),Lbl);
  else
    //zcConst,zcIdentifier,zcFuncCall etc
    DoGenValue;
  end;
end;

//Fall igenom om true, annars hoppa till Lbl
procedure TZCodeGen.FallTrue(Op: TZcOp; Lbl: TZCodeLabel);

  procedure DoGenComp(Kind : TExpOpJumpKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    GenJump(Kind,Lbl,Op.Child(0).GetDataType.Kind);
  end;

  procedure DoGenAnd;
  begin
    FallTrue(Op.Child(0),Lbl);
    FallTrue(Op.Child(1),Lbl);
  end;

  procedure DoGenOr;
  var
    LOr : TZCodeLabel;
  begin
    LOr := NewLabel;
    FallFalse(Op.Child(0),LOr);
    FallTrue(Op.Child(1),Lbl);
    DefineLabel(LOr);
  end;

  procedure DoGenValue;
  begin
    //if(1) blir: value,0, compare and jump
    if (Op.Kind=zcConstLiteral) and (TZcOpLiteral(Op).Typ.Kind in [zctInt,zctByte]) then
    begin
      if TZcOpLiteral(Op).Value=0 then
        GenJump(jsJumpAlways,Lbl, Op.GetDataType.Kind);
    end else
    begin
      GenValue(Op);
      MakeLiteralOp(0, Op.GetDataType);
      GenJump(jsJumpEQ,Lbl,Op.GetDataType.Kind);
    end;
  end;

begin
  case Op.Kind of
    //Generera varje j�mf�relses motsats
    zcCompLT : DoGenComp(jsJumpGE);
    zcCompGT : DoGenComp(jsJumpLE);
    zcCompEQ : DoGenComp(jsJumpNE);
    zcCompNE : DoGenComp(jsJumpEQ);
    zcCompLE : DoGenComp(jsJumpGT);
    zcCompGE : DoGenComp(jsJumpLT);
    zcAnd : DoGenAnd;
    zcOr : DoGenOr;
    zcNot : FallFalse(Op.Child(0),Lbl);
  else
    //zcConst,zcIdentifier,zcFuncCall etc
    DoGenValue;
  end;
end;

procedure TZCodeGen.GenFuncCall(Op: TZcOp; NeedReturnValue : boolean);

  procedure DoGenBuiltInFunc(Func : TZcOpFunctionBuiltIn);
  var
    I : integer;
    F : TExpFuncCallBase;
  begin
    if NeedReturnValue and (Func.ReturnType.Kind=zctVoid) then
      raise ECodeGenError.Create('Function in expression must return a value: ' + Op.Id);
    if Op.Children.Count<>Func.Arguments.Count then
      raise ECodeGenError.Create('Invalid nr of arguments: ' + Op.Id);
    for I := 0 to Func.Arguments.Count-1 do
      if Func.Arguments[I].Typ.IsPointer then
        GenAddress(Op.Child(I))
      else
        GenValue(Op.Child(I));
    if Func.FuncId in [fcIntToStr,fcSubStr,fcChr,fcCreateModel] then
    begin
      F := TExpPointerFuncCall.Create(Target);
    end else if Func.FuncId in [fcMatMultiply,fcMatTransformPoint,fcGetMatrix,fcSetMatrix,fcVec2,fcVec3,fcVec4] then
    begin
      F := TExpMat4FuncCall.Create(Target);
    end else if Func.FuncId in [fcFindComponent,fcCreateComponent,fcSetNumericProperty,fcSetStringProperty,
      fcSetObjectProperty,fcSaveComponentToTextFile,fcGetStringProperty] then
    begin
      F := TExpIDEFuncCall.Create(Target);
    end else
    begin
      F := TExpFuncCall.Create(Target);
    end;
    F.Kind := Func.FuncId;
    if (not NeedReturnValue) and (Func.ReturnType.Kind<>zctVoid) then
      //discard return value from stack
      TExpMisc.Create(Target, emPop);
  end;

  procedure DoGenUserFunc(UserFunc : TZcOpFunctionUserDefined);
  var
    I : integer;
    F : TExpUserFuncCall;
    FE : TExpExternalFuncCall;
    S : AnsiString;
    Arg : TZcOpArgumentVar;
    VF : TExpVirtualFuncCall;
  begin
    if NeedReturnValue and (UserFunc.ReturnType.Kind=zctVoid) then
      raise ECodeGenError.Create('Function in expression must return a value: ' + Op.Id);
    if Op.Children.Count<>UserFunc.Arguments.Count then
      raise ECodeGenError.Create('Invalid nr of arguments: ' + Op.Id);

    for I := 0 to UserFunc.Arguments.Count-1 do
    begin
      if UserFunc.Arguments[I].Typ.IsPointer then
        GenAddress(Op.Child(I))
      else
        GenValue(Op.Child(I));
    end;

    if UserFunc.IsExternal then
    begin
      FE := TExpExternalFuncCall.Create(Target);
      FE.Lib := UserFunc.ExtLib;
      FE.SetString('FuncName',AnsiString(UserFunc.Id));
      FE.ArgCount := UserFunc.Arguments.Count;
      FE.ReturnType := UserFunc.ReturnType;
      S := '';
      for Arg in UserFunc.Arguments do
      begin
        //Use +65 to avoid #0 character in string
        if Arg.Typ.IsPointer then
          S := S + AnsiChar( Ord(zctXptr)+65 )
        else
          S := S + AnsiChar( Ord(Arg.Typ.Kind)+65 );
      end;
      FE.SetString('ArgTypes',S);
    end
    else
    begin
      if (mdVirtual in UserFunc.Modifiers) or (mdOverride in UserFunc.Modifiers) then
      begin
        GenValue(Op.Child(0)); //load "this" as parameter for TExpVirtualFuncCall
        VF := TExpVirtualFuncCall.Create(Target);
        VF.VmtIndex := UserFunc.VmtIndex;
      end else
      begin
        F := TExpUserFuncCall.Create(Target);
        F.Lib := UserFunc.Lib;
        F.Index := UserFunc.LibIndex;
        F.Ref := UserFunc;
      end;
    end;

    if (not NeedReturnValue) and (UserFunc.ReturnType.Kind<>zctVoid) then
      //discard return value from stack
      TExpMisc.Create(Target, emPop);
  end;

var
  MangledName : string;
  O : TObject;
  Cls : TZcOpClass;
begin
  Assert(Op.Kind in [zcFuncCall,zcMethodCall]);

  if Op.Kind=zcFuncCall then
  begin
    MangledName := MangleFunc(Op.Id,Op.Children.Count);
    O := SymTab.Lookup(MangledName);
  end else
  begin
    Cls := Op.Ref as TZcOpClass;
    MangledName := MangleFunc(Op.Id,Op.Children.Count);
    O := Cls.FindMethod(MangledName);
    if (O=nil) and SameText(MangledName,Cls.Initializer.MangledName) then
      O := Cls.Initializer;
  end;

  if Assigned(O) and (O is TZcOpFunctionUserDefined) then
  begin
    DoGenUserFunc(O as TZcOpFunctionUserDefined);
  end else if Assigned(O) and (O is TZcOpFunctionBuiltIn) then
  begin
    DoGenBuiltInFunc(O as TZcOpFunctionBuiltIn);
  end else raise ECodeGenError.Create('Unknown function: ' + Op.Id);
end;

{ TZCodeLabel }

constructor TZCodeLabel.Create;
begin
  Usage := Contnrs.TObjectList.Create;
  Self.Definition := -1;
end;

destructor TZCodeLabel.Destroy;
begin
  Usage.Free;
  inherited;
end;

function TZCodeLabel.IsDefined: boolean;
begin
  Result := Definition<>-1;
end;

//////////////////////////


function CloseComment(const S: string) : string;
var
  I : integer;
begin
  Result := S;
  I := S.LastIndexOf('/*');
  if (I>-1) and ((I=1) or (S[I]<>'/')) then
    if S.LastIndexOf('*/')<I then
      Result := S + '*/';
end;

procedure Compile(ZApp: TZApplication; ThisC : TZComponent; const Ze : TZExpressionPropValue;
  SymTab : TSymbolTable; const ReturnType : TZcDataType;
  GlobalNames : Contnrs.TObjectList;
  ExpKind : TExpressionKind);
var
  Compiler : TZc;
  CodeGen : TZCodeGen;
  I : integer;
  S : string;
  Target : TZComponentList;
  HasCode : boolean;
begin
  S := Ze.Source;
  Target := Ze.Code;

  if ThisC is TZLibrary then
  begin //Reset global variables
    (ThisC as TZLibrary).GlobalAreaSize := 0;
    (ThisC as TZLibrary).ManagedVariables.Size := 0;
  end;

  CompilerContext.SymTab := SymTab;
  CompilerContext.ThisC := ThisC;
  CompilerContext.FunctionCleanUps := ZApp.FunctionCleanUps;

  SymTab.PushScope; //Create a scope for private vars and functions
  Compiler := TZc.Create(nil);
  try
    case ExpKind of
      ekiNormal:
        begin
          S := 'private ' + GetZcTypeName(ReturnType) + ' __f() { '#13#10 + CloseComment(S) + #13#10'}';
        end;
      ekiLibrary:
        begin
          Compiler.AllowInitializer := (ThisC is TZLibrary) and (ThisC.OwnerList=ThisC.ZApp.OnLoaded);
        end;
      ekiGetValue:
        begin
          S := 'private float __f() { return ' + CloseComment(S) + #13#10'; }';
        end;
      ekiGetPointer:
        begin
          S := 'private model __f() { __getLValue( ' + CloseComment(S) + ' ); return null; }';
        end;
      ekiBitmap :
        begin
          S := 'private void __f(float x, float y, vec4 pixel) { ' + CloseComment(S) + #13#10' }';
        end;
      ekiMesh :
        begin
          S := 'private void __f(vec3 v, vec3 n, vec4 c, vec2 texcoord) { ' + CloseComment(S) + #13#10' }';
        end;
      ekiThread :
        begin
          S := 'private void __f(int param) { ' + CloseComment(S) + #13#10' }';
        end;
      ekiGetStringValue:
        begin
          S := 'private string __f() { return ' + CloseComment(S) + '; }';
        end;
    end;

    Compiler.SymTab := SymTab;
    Compiler.GlobalNames := GlobalNames;
    Compiler.ZApp := ZApp;

    Compiler.SetSource(S);
    Compiler.LookAroundGap(1,10);

    try
      Compiler.Execute;
    finally
      SymTab.Remove('__f');
    end;

    if Compiler.Successful then
    begin
      for I:=0 to Compiler.ZFunctions.Count-1 do
        Compiler.ZFunctions[I] := TZcOp(Compiler.ZFunctions[I]).Optimize;
    end else
      raise EParseError.Create('Compilation failed');

    if ThisC is TZLibrary then
    begin
      (ThisC as TZLibrary).HasInitializer := Assigned(Compiler.InitializerFunction);
      (ThisC as TZLibrary).DesignerReset; //Neccessary to init globalarea
    end;

    Target.Clear;
    CodeGen := TZCodeGen.Create;
    try
      CodeGen.Target := Target;
      CodeGen.Component := ThisC;
      CodeGen.SymTab := SymTab;
      CodeGen.ZApp := ZApp;
      try
        CodeGen.GenRoot(Compiler.ZFunctions);
      except
        //Om n�got g�r fel under kodgenereringen s� rensa koden s� att den inte k�rs
        Target.Clear;
        raise;
      end;

      if (ExpKind=ekiGetPointer) and (Target.Count>0) then
      begin  //Only keep the 'get lvalue address' code (and code to return from expression)
        I := Target.Count;
        while (I>0) do
        begin
          Dec(I);
          if (Target.Items[I] is TExpMisc) and (TExpMisc(Target.Items[I]).Kind=emLoadNull)  then
            Target.Items[I].Free;  //remove the "null" from "return null"
          if Target.Items[I] is TExpFuncCall then
          begin //remove the __getLValue call. This will make the code return the lvalue instead of null.
            Target.Items[I].Free;
            Break;
          end;
        end;
      end;

     if (ExpKind=ekiNormal) and (Target.Count<=2) then
      begin //An expression that is only ExpStackFrame and ExpReturn can be omitted (empty WhileExp etc)
        HasCode := False;
        for I := 0 to Target.Count-1 do
          if not ((Target[I] is TExpStackFrame) or (Target[I] is TExpReturn)) then
            HasCode := True;
        if not HasCode then
          Target.Clear;
      end;

      if (ExpKind > ekiLibrary) and (Target.Count>0) then
      begin
        //We don't want expreturn to clean up stack on exit
        (Target.Items[Target.Count-1] as TExpReturn).Arguments := 0;
      end;

      //Show tree as source-code for debugging
      CompileDebugString := '';
      for I := 0 to Compiler.ZFunctions.Count-1 do
        CompileDebugString := CompileDebugString + (Compiler.ZFunctions[I] as TZcOp).ToString + #13#10;

    finally
      CodeGen.Free;
    end;
  finally
    SymTab.PopScope;
    Compiler.Free;
  end;

end;

function CompileEvalExpression(const Expr : string;
  App : TZApplication;
  TargetCode : TZComponentList) : TZcDataType;
var
  Compiler : TZc;
  CodeGen : TZCodeGen;
begin
  Result.Kind := zctVoid;

  CompilerContext.SymTab := App.SymTab;
  CompilerContext.ThisC := nil;
  CompilerContext.FunctionCleanUps := App.FunctionCleanUps;

  Compiler := TZc.Create(nil);
  try
    Compiler.SymTab := App.SymTab;
    Compiler.ZApp := App;

    Compiler.SetSource(Expr);
    Compiler.ParseEvalExpression;

    if not Compiler.Successful then
      raise EParseError.Create('Compilation failed');

    Result := (Compiler.ZFunctions.First as TZcOp).GetDataType;

    TargetCode.Clear;
    CodeGen := TZCodeGen.Create;
    try
      CodeGen.Target := TargetCode;
      CodeGen.Component := nil;
      CodeGen.SymTab := App.SymTab;
      CodeGen.ZApp := App;
      try
        CodeGen.GenRoot(Compiler.ZFunctions);
      except
        TargetCode.Clear;
        raise;
      end;
    finally
      CodeGen.Free;
    end;

  finally
    Compiler.Free;
  end;
end;

{ EZcErrorBase }

constructor EZcErrorBase.Create(const M: string);
begin
  Self.Message := M;
  Self.Component := CompilerContext.ThisC;
end;

end.

