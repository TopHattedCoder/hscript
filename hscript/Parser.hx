/*
 * Copyright (c) 2008, Nicolas Cannasse
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package hscript;
import hscript.Expr;

enum Token {
	TEof;
	TConst( c : Const );
	TId( s : String );
	TOp( s : String );
	TPOpen;
	TPClose;
	TBrOpen;
	TBrClose;
	TDot;
	TComma;
	TSemicolon;
	TBkOpen;
	TBkClose;
	TQuestion;
	TDoubleDot;
	THash;
	TInterp(s:String);
}

class Parser {

	// config / variables
	public var line : Int;
	public var opChars : String;
	public var identChars : String;
	#if haxe3
	public var opPriority : Map<String,Int>;
	public var opRightAssoc : Map<String,Bool>;
	public var unops : Map<String,Bool>; // true if allow postfix
	#else
	public var opPriority : Hash<Int>;
	public var opRightAssoc : Hash<Bool>;
	public var unops : Hash<Bool>; // true if allow postfix
	#end
	public var currentPackage : Array<String>;
	/**
		activate JSON compatiblity
	**/
	public var allowJSON : Bool;

	// implementation
	var input : haxe.io.Input;
	var char : Int;
	var ops : Array<Bool>;
	var idents : Array<Bool>;

	#if hscriptPos
	var readPos : Int;
	var tokenMin : Int;
	var tokenMax : Int;
	var oldTokenMin : Int;
	var oldTokenMax : Int;
	var tokens : List<{ min : Int, max : Int, t : Token }>;
	#else
	static inline var p1 = 0;
	static inline var readPos = 0;
	static inline var tokenMin = 0;
	static inline var tokenMax = 0;
	#if haxe3
	var tokens : haxe.ds.GenericStack<Token>;
	#else
	var tokens : haxe.FastList<Token>;
	#end
	
	#end


	public function new() {
		line = 1;
		opChars = "+*/-=!><&|^%~";
		identChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
		currentPackage = [];
		var priorities = [
			["%"],
			["*", "/"],
			["+", "-"],
			["<<", ">>", ">>>"],
			["|", "&", "^"],
			["==", "!=", ">", "<", ">=", "<="],
			["..."],
			["&&"],
			["||"],
			["=","+=","-=","*=","/=","%=","<<=",">>=",">>>=","|=","&=","^="],
		];
		opPriority = new Map();
		opRightAssoc = new Map();
		unops = new Map();
		for( i in 0...priorities.length )
			for( x in priorities[i] ) {
				opPriority.set(x, i);
				if( i == 9 ) opRightAssoc.set(x, true);
			}
		for( x in ["!", "++", "--", "-", "~"] )
			unops.set(x, x == "++" || x == "--");
	}

	public function error( err:ErrorDef, pmin:Int, pmax:Int ) {
		throw new Error(err, pmin, pmax);
	}

	public function invalidChar(c) {
		error(EInvalidChar(c), readPos, readPos);
	}

	public function parseString( s : String ) {
		line = 1;
		return parse( new haxe.io.StringInput(s) );
	}

	public function parse( s : haxe.io.Input ) {
		#if hscriptPos
		readPos = 0;
		tokenMin = oldTokenMin = 0;
		tokenMax = oldTokenMax = 0;
		tokens = new List();
		#elseif haxe3
		tokens = new haxe.ds.GenericStack<Token>();
		#else
		tokens = new haxe.FastList<Token>();
		#end
		char = -1;
		input = s;
		ops = new Array();
		idents = new Array();
		for( i in 0...opChars.length )
			ops[opChars.charCodeAt(i)] = true;
		for( i in 0...identChars.length )
			idents[identChars.charCodeAt(i)] = true;
		var a = new Array();
		while( true ) {
			var tk = token();
			if( tk == TEof ) break;
			push(tk);
			a.push(parseFullExpr());
		}
		return if( a.length == 1 ) a[0] else mk(EBlock(a),0);
	}

	function unexpected( tk , ?info:String) : Dynamic {
		error(EUnexpected("'"+tokenString(tk) + "'"+(info == null?"":" - expected " + info)),tokenMin,tokenMax);
		return null;
	}

	function push(tk) {
		#if hscriptPos
		tokens.push( { t : tk, min : tokenMin, max : tokenMax } );
		tokenMin = oldTokenMin;
		tokenMax = oldTokenMax;
		#else
		tokens.add(tk);
		#end
	}

	inline function ensure(tk) {
		var t = token();
		if( t != tk ) unexpected(t);
	}
	inline function mk(e:ExprDef,?pmin,?pmax):Expr {
		if( pmin == null ) pmin = tokenMin;
		if( pmax == null ) pmax = tokenMax;
		return new Expr(e, pmin, pmax);
	}

	function isBlock(e) {
		return switch(e.expr) {
			case EClassDecl(_) | EEnumDecl(_): true;
			case EBlock(_), EObject(_): true;
			case EFunction(_,e,_,_): isBlock(e);
			case EVars([]): false;
			case EVars(vs):	vs[0].expr != null && isBlock(vs[0].expr);
			case EIf(_,e1,e2): if( e2 != null ) isBlock(e2) else isBlock(e1);
			case EBinop(_,_,e): isBlock(e);
			case EUnop(_,prefix,e): !prefix && isBlock(e);
			case EWhile(_,e): isBlock(e);
			case EFor(_,_,e): isBlock(e);
			case EReturn(e): e != null && isBlock(e);
			case ESwitch(_, _, _): true;
			default: false;
		}
	}

	function parseFullExpr() {
		var e = parseExpr();
		var tk = token();
		if( tk != TSemicolon && tk != TEof ) {
			if(isBlock(e))
				push(tk);
			else
				unexpected(tk);
		}
		return e;
	}

	function parseObject(p1) {
		// parse object
		var fl = new Array();
		while( true ) {
			var tk = token();
			var id = null;
			switch( tk ) {
			case TId(i): id = i;
			case TConst(c):
				if( !allowJSON )
					unexpected(tk);
				switch( c ) {
					case CString(s): id = s;
					default: unexpected(tk);
				}
			case TBrClose:
				break;
			default:
				unexpected(tk);
			}
			ensure(TDoubleDot);
			fl.push({ name : id, e : parseExpr() });
			tk = token();
			switch( tk ) {
			case TBrClose:
				break;
			case TComma:
			default:
				unexpected(tk);
			}
		}
		return parseExprNext(mk(EObject(fl),p1));
	}
	function parseExpr() {
		var tk = token();
		var p1 = tokenMin;
		switch( tk ) {
		case TInterp(s):
			var is = parseInterpolatedString(s);
			return parseExprNext(is);
		case THash:
			var tk = null;
			var name = switch(tk = token()) {
				case TId(s): s;
				default: unexpected(tk);
			};
			var args = [while((tk = token()).getName() == "TId")
				tk.getParameters()[0]
			];
			var expr:Expr = mk(EBlock([]));
			switch(name) {
				case "if":
					expr = parseExpr();
					
				default: unexpected(TId("#"+name));
			}
			return expr;
		case TId(id):
			var e = parseStructure(id);
			if( e == null )
				e = mk(EIdent(id));
			return parseExprNext(e);
		case TConst(c):
			return parseExprNext(mk(EConst(c)));
		case TPOpen:
			var e = parseExpr();
			ensure(TPClose);
			return parseExprNext(mk(EParent(e),p1,tokenMax));
		case TBrOpen:
			tk = token();
			switch( tk ) {
			case TBrClose:
				return parseExprNext(mk(EObject([]),p1));
			case TId(_):
				var tk2 = token();
				push(tk2);
				push(tk);
				switch( tk2 ) {
				case TDoubleDot:
					return parseExprNext(parseObject(p1));
				default:
				}
			case TConst(c):
				if( allowJSON ) {
					switch( c ) {
					case CString(_):
						var tk2 = token();
						push(tk2);
						push(tk);
						switch( tk2 ) {
						case TDoubleDot:
							return parseExprNext(parseObject(p1));
						default:
						}
					default:
						push(tk);
					}
				} else
					push(tk);
			default:
				push(tk);
			}
			var a = new Array();
			while( true ) {
				a.push(parseFullExpr());
				tk = token();
				if( tk == TBrClose )
					break;
				push(tk);
			}
			return mk(EBlock(a),p1);
		case TOp(op):
			if( unops.exists(op) )
				return makeUnop(op,parseExpr());
			return unexpected(tk);
		case TBkOpen:
			var a = new Array();
			tk = token();
			while( tk != TBkClose ) {
				push(tk);
				a.push(parseExpr());
				tk = token();
				if( tk == TComma )
					tk = token();
			}
			return parseExprNext(mk(EArrayDecl(a),p1));
		default:
			return unexpected(tk);
		}
	}

	function makeUnop(op:String, e:Expr) {
		return switch(e.expr) {
			case EBinop(bop, e1, e2): mk(EBinop(bop, makeUnop(op, e1), e2), e1.pmin, e2.pmax);
			case ETernary(e1, e2, e3): mk(ETernary(makeUnop(op, e1), e2, e3), e1.pmin, e3.pmax);
			default: mk(EUnop(op,true,e),e.pmin,e.pmax);
		}
	}

	function makeBinop( op:String, e1:Expr, e:Expr) {
		return switch(e.expr) {
		case EBinop(op2,e2,e3):
			if( opPriority.get(op) <= opPriority.get(op2) && !opRightAssoc.exists(op) )
				mk(EBinop(op2,makeBinop(op,e1,e2),e3),e1.pmin, e3.pmax);
			else
				mk(EBinop(op, e1, e), e1.pmin, e.pmax);
		case ETernary(e2,e3,e4):
			if( opRightAssoc.exists(op) )
				mk(EBinop(op,e1,e),e1.pmin,e.pmax);
			else
				mk(ETernary(makeBinop(op, e1, e2), e3, e4), e1.pmin, e.pmax);
		default:
			mk(EBinop(op,e1,e),e1.pmin,e.pmax);
		}
	}

	function parseStructure(id) {
		var p1 = tokenMin;
		return switch( id ) {
			case "enum":
				var name:String = switch(token()) {
					case TId(s): s;
					case all: unexpected(all);
				};
				var ed:EnumDecl = {
					name: name,
					constructors: new Map()
				};
				ensure(TBrOpen);
				var tk = null;
				var cf:EnumConst = [];
				var name = null;
				var inParams = false;
				while((tk = token()) != Token.TBrClose) {
					switch(tk) {
						case TId(nm) if(name == null): name = nm;
						case TId(nm) if(inParams): cf.push({name: nm});
						case TDoubleDot if(inParams && cf.length > 0): cf[cf.length-1].type = parseType();
						case TPOpen if(name != null): inParams = true;
						case TPClose if(inParams): inParams = false;
						case TSemicolon if(!inParams):
							ed.constructors.set(name, cf);
							name = null;
							cf = [];
						default: unexpected(tk);
					};
				}
				mk(EEnumDecl(ed));
			case "class", "interface":
				var isInterface = id == "interface";
				var name:String = switch(token()) {
					case TId(s): s;
					case all: unexpected(all);
				};
				var flags = new haxe.EnumFlags();
				if(id == "interface")
					flags.set(ClassFlag.IsInterface);
				var cd:ClassDecl = {
					pack: currentPackage,
					name: name,
					fields: new Map(),
					flags: flags
				};
				ensure(TBrOpen);
				var tk = null;
				while(tk != Token.TBrClose) {
					var field:Field = {access: new haxe.EnumFlags()};
					var name = null;
					var canSkip = false;
					while((tk = token()) != Token.TSemicolon && tk != Token.TBrClose) {
						switch(tk) {
							case _ if(canSkip): push(tk); field.expr = parseExpr(); canSkip = false;
							case TId("public"): field.access.set(Access.Public);
							case TId("private"): field.access.set(Access.Private);
							case TId("static"): field.access.set(Access.Static);
							case TId("var"): name = switch(tk = token()) {
								case TId(s): s;
								case all: unexpected(all);
							}
							case TPOpen if(name != null):
								switch(tk = token()) {
									case TId("get"): field.access.set(HasGetter);
									case TId("never"|"null"|"default"):
									default: unexpected(tk);
								};
								ensure(TComma);
								switch(tk = token()) {
									case TId("set"): field.access.set(HasSetter);
									case TId("never"|"null"|"default"):
									default: unexpected(tk);
								};
								ensure(TPClose);
							case TDoubleDot: field.type = parseType(); //canSkip = true;
							case TId("function"):
								push(tk);
								field.expr = parseExpr();
								switch(field.expr.expr) {
									case EFunction(a, b, n, c):
										name = n;
										field.expr = mk(EFunction(a, b, null, c));
									case all: throw EInvalidFunction;
								};
								field.access.set(Function);
							case TOp("="): field.expr = parseExpr();
							case TSemicolon: break;
							default: unexpected(tk);
						}
						if(name != null)
							if(name == "new")
								cd.constructor = field;
							else
								cd.fields.set(name, field);
					}
				};
				mk(EClassDecl(cd), p1, tokenMax);
			case "if":
				var cond = parseExpr();
				var e1 = parseExpr();
				var e2 = null;
				var semic = false;
				var tk = token();
				if( tk == TSemicolon ) {
					semic = true;
					tk = token();
				}
				if( Type.enumEq(tk,TId("else")) )
					e2 = parseExpr();
				else {
					push(tk);
					if( semic ) push(TSemicolon);
				}
				mk(EIf(cond,e1,e2),p1,(e2 == null) ? tokenMax : e2.pmax);
			case "var":
				var vars:Array<Var> = [];
				var tk = null;
				vars = [while((tk = tk == null ? token() : tk) != Token.TSemicolon) {
					var ident = null, type = null, expr = null;
					while(tk == Token.TComma)
						tk = token();
					switch(tk) {
						case TId(id): ident = id;
						default: unexpected(tk, "identifier");
					}
					tk = token();
					switch(tk) {
						case TDoubleDot if(type == null):
							type = parseType();
							tk = token();
						default:
					}
					switch(tk) {
						case TOp("="):
							expr = parseExpr();
							tk = token();
						case TSemicolon, TComma:
						case _ if(type != null):
							push(tk);
							expr = parseExpr();
							tk = token();
						default: unexpected(tk, "type or assignment");
					}
					{name: ident, type: type, expr: expr};
				}];
				push(tk);
				mk(EVars(vars),p1, tokenMax);
			case "while":
				var econd = parseExpr();
				var e = parseExpr();
				mk(EWhile(econd,e),p1,e.pmax);
			case "for":
				ensure(TPOpen);
				var tk = token();
				var vname = null;
				switch( tk ) {
				case TId(id): vname = id;
				default: unexpected(tk);
				}
				tk = token();
				if( !Type.enumEq(tk,TId("in")) ) unexpected(tk);
				var eiter = parseExpr();
				ensure(TPClose);
				var e = parseExpr();
				mk(EFor(vname,eiter,e),p1,e.pmax);
			case "switch":
				ensure(TPOpen);
				var val = parseExpr();
				ensure(TPClose);
				ensure(Token.TBrOpen);
				var cases:Array<Case> = [];
				var def:Expr = null;
				while(true) {
					var tk = token();
					switch(tk) {
						case TId("case"):
							var allowed:Array<Expr> = [];
							allowed.push(parseExpr());
							var guard:Expr = null;
							var ntk = null;
							while(true) {
								switch(ntk = token()) {
									case Token.TComma | Token.TOp("|"):

									case Token.TId("if"):
										ensure(TPOpen);
										guard = parseExpr();
										ensure(TPClose);
										ntk = token();
										break;
									default: break;
								}
								allowed.push(parseExpr());
							}
							switch(ntk) {
								case TDoubleDot:
								default: unexpected(ntk);
							}
							var expr:Expr = parseExpr();
							ensure(TSemicolon);
							cases.push({values: allowed, expr: expr, guard: guard});
						case TId("default"):
							ensure(TDoubleDot);
							def = parseExpr();
							ensure(TSemicolon);
						case TBrClose:
							break;
						default: unexpected(tk);
					}
				}
				mk(ESwitch(val, cases, def));
			case "break": mk(EBreak);
			case "continue": mk(EContinue);
			case "untyped": mk(EUntyped(parseExpr()));
			case "using":
				mk(EUsing(parseExpr()));
			case "import":
				var expr = parseExpr();
				var name = switch(expr.expr) {
					case EField(_, f): f;
					default: null;
				}
				var tk = token();
				switch(tk) {
					case TId("in"):
						name = switch(token()) {
							case TId(id): id;
							case all: unexpected(all);
						}
					default: push(tk);
				}
				mk(EVars([{name: name, expr: expr}]));
			case "else": unexpected(TId(id));
			case "function":
				var tk = token();
				var name = null;
				switch( tk ) {
					case TId(id): name = id;
					default: push(tk);
				}
				ensure(TPOpen);
				var args = new Array();
				tk = token();
				if( tk != TPClose ) {
					var arg = true;
					while( arg ) {
						var name = null;
						switch( tk ) {
							case TId(id): name = id;
							default: unexpected(tk);
						}
						tk = token();
						var t = null;
						if( tk == TDoubleDot) {
							t = parseType();
							tk = token();
						}
						args.push( { name : name, t : t } );
						switch( tk ) {
						case TComma:
							tk = token();
						case TPClose:
							arg = false;
						default:
							unexpected(tk);
						}
					}
				}
				var ret = null;
				tk = token();
				if( tk != TDoubleDot )
					push(tk);
				else
					ret = parseType();
				var body = parseExpr();
				mk(EFunction(args, body, name, ret),p1,body.pmax);
			case "return":
				var tk = token();
				push(tk);
				var e = if( tk == TSemicolon ) null else parseExpr();
				mk(EReturn(e),p1,if( e == null ) tokenMax else e.pmax);
			case "new":
				var a = new Array();
				var tk = token();
				switch( tk ) {
					case TId(id): a.push(id);
					default: unexpected(tk);
				}
				var next = true, hasType = false;
				while(next) {
					tk = token();
					switch( tk ) {
						case TOp("<"):
							parseType();
							hasType = true;
						case TOp(">"):
							hasType = false;
						case TComma if(hasType):
							parseType();
						case TDot:
							tk = token();
							switch(tk) {
							case TId(id): a.push(id);
							default: unexpected(tk);
							}
						case TPOpen:
							next = false;
						default:
							unexpected(tk);
					}
				}
				var args = parseExprList(TPClose);
				mk(ENew(a.join("."),args),p1);
			case "throw":
				var e = parseExpr();
				mk(EThrow(e),p1,e.pmax);
			case "try":
				var e = parseExpr();
				var tk = token();
				if( !Type.enumEq(tk, TId("catch")) ) unexpected(tk);
				ensure(TPOpen);
				tk = token();
				var vname = switch( tk ) {
				case TId(id): id;
				default: unexpected(tk);
				}
				ensure(TDoubleDot);
				var t = parseType();
				ensure(TPClose);
				var ec = parseExpr();
				mk(ETry(e,vname,t,ec),p1,ec.pmax);
			case "package":
				var pckg:Array<String> = [];
				var tk = null, shouldDot = false;
				while((tk = token()) != TSemicolon) {
					switch(tk) {
						case TId(id):
							pckg.push(id);
							shouldDot = true;
						case TDot if(shouldDot):

						default: unexpected(tk);
					}
				}
				push(tk);
				this.currentPackage = pckg;
				mk(EBlock([]), p1, p1);
			default:
				null;
		}
	}

	function parseExprNext( e1 : Expr ) {
		var tk = token();
		switch( tk ) {
		case TOp(op):
			if( unops.get(op) ) {
				if( isBlock(e1) || switch(e1.expr) { case EParent(_): true; default: false; } ) {
					push(tk);
					return e1;
				}
				return parseExprNext(mk(EUnop(op,false,e1),e1.pmin));
			}
			return makeBinop(op,e1,parseExpr());
		case TDot:
			tk = token();
			var field = null;
			switch(tk) {
			case TId(id): field = id;
			default: unexpected(tk);
			}
			return parseExprNext(mk(EField(e1,field),e1.pmin));
		case TPOpen:
			return parseExprNext(mk(ECall(e1,parseExprList(TPClose)),e1.pmin));
		case TBkOpen:
			var e2 = parseExpr();
			ensure(TBkClose);
			return parseExprNext(mk(EArray(e1,e2),e1.pmin));
		case TQuestion:
			var e2 = parseExpr();
			ensure(TDoubleDot);
			var e3 = parseExpr();
			return mk(ETernary(e1,e2,e3),e1.pmin,e3.pmax);
		default:
			push(tk);
			return e1;
		}
	}

	function parseType() : CType {
		var t = token();
		switch(t) {
			case TId(v):
				var path = [v];
				while( true ) {
					t = token();
					if( t != TDot )
						break;
					t = token();
					switch( t ) {
						case TId(v):
							path.push(v);
						default:
							unexpected(t);
					}
				}
				var params = null;
				switch( t ) {
					case TOp("<"):
						params = [];
						while(true) {
							params.push(parseType());
							t = token();
							switch( t ) {
								case TComma: continue;
								case TOp(">"): break;
								default:
							}
							unexpected(t);
						}
					default:
						push(t);
				}
				return parseTypeNext(CTPath(path, params));
			case TPOpen:
				var t = parseType();
				ensure(TPClose);
				return parseTypeNext(CTParent(t));
			case TBrOpen:
				var fields = [];
				while( true ) {
					t = token();
					switch( t ) {
					case TBrClose: break;
					case TId(name):
						ensure(TDoubleDot);
						fields.push( { name : name, t : parseType() } );
						t = token();
						switch( t ) {
						case TComma:
						case TBrClose: break;
						default: unexpected(t);
						}
					default:
						unexpected(t);
					}
				}
				return parseTypeNext(CTAnon(fields));
			default:
				return unexpected(t);
		}
	}

	function parseTypeNext( t : CType ) {
		var tk = token();
		switch(tk) {
			case TOp(op):
				if( op != "->" ) {
					push(tk);
					return t;
				}
			default:
				push(tk);
				return t;
			}
			var t2 = parseType();
			switch( t2 ) {
			case CTFun(args, _):
				args.unshift(t);
				return t2;
			default:
				return CTFun([t], t2);
		}
	}

	function parseExprList( etk ) {
		var args = new Array();
		var tk = token();
		if( tk == etk )
			return args;
		push(tk);
		while( true ) {
			args.push(parseExpr());
			tk = token();
			switch( tk ) {
			case TComma:
			default:
				if( tk == etk ) break;
				unexpected(tk);
			}
		}
		return args;
	}

	inline function incPos() {
		#if hscriptPos
		readPos++;
		#end
	}

	function readChar() {
		incPos();
		return try input.readByte() catch( e : Dynamic ) 0;
	}

	function readString( until ) {
		var c = 0;
		var b = new haxe.io.BytesOutput();
		var esc = false;
		var old = line;
		var s = input;
		#if hscriptPos
		var p1 = readPos - 1;
		#end
		while( true ) {
			try {
				incPos();
				c = s.readByte();
			} catch( e : Dynamic ) {
				line = old;
				error(EUnterminatedString, p1, p1);
			}
			if( esc ) {
				esc = false;
				switch( c ) {
				case 'n'.code: b.writeByte(10);
				case 'r'.code: b.writeByte(13);
				case 't'.code: b.writeByte(9);
				case "'".code, '"'.code, '\\'.code: b.writeByte(c);
				case '/'.code: if( allowJSON ) b.writeByte(c) else invalidChar(c);
				case "u".code:
					if( !allowJSON ) throw invalidChar(c);
					var code = null;
					try {
						incPos();
						incPos();
						incPos();
						incPos();
						code = s.readString(4);
					} catch( e : Dynamic ) {
						line = old;
						error(EUnterminatedString, p1, p1);
					}
					var k = 0;
					for( i in 0...4 ) {
						k <<= 4;
						var char = code.charCodeAt(i);
						switch( char ) {
						case 48,49,50,51,52,53,54,55,56,57: // 0-9
							k += char - 48;
						case 65,66,67,68,69,70: // A-F
							k += char - 55;
						case 97,98,99,100,101,102: // a-f
							k += char - 87;
						default:
							invalidChar(char);
						}
					}
					// encode k in UTF8
					if( k <= 0x7F )
						b.writeByte(k);
					else if( k <= 0x7FF ) {
						b.writeByte( 0xC0 | (k >> 6));
						b.writeByte( 0x80 | (k & 63));
					} else {
						b.writeByte( 0xE0 | (k >> 12) );
						b.writeByte( 0x80 | ((k >> 6) & 63) );
						b.writeByte( 0x80 | (k & 63) );
					}
				default: invalidChar(c);
				}
			} else if( c == 92 )
				esc = true;
			else if( c == until )
				break;
			else {
				if( c == 10 ) line++;
				b.writeByte(c);
			}
		}
		return b.getBytes().toString();
	}

	function token() {
		#if hscriptPos
		var t = tokens.pop();
		if( t != null ) {
			tokenMin = t.min;
			tokenMax = t.max;
			return t.t;
		}
		oldTokenMin = tokenMin;
		oldTokenMax = tokenMax;
		tokenMin = (this.char < 0) ? readPos : readPos - 1;
		var t = _token();
		tokenMax = (this.char < 0) ? readPos - 1 : readPos - 2;
		return t;
	}

	function _token() {
		#else
		if( !tokens.isEmpty() )
			return tokens.pop();
		#end
		var char;
		if( this.char < 0 )
			char = readChar();
		else {
			char = this.char;
			this.char = -1;
		}
		while( true ) {
			switch( char ) {
			case 0: return TEof;
			case 32,9,13: // space, tab, CR
				#if hscriptPos
				tokenMin++;
				#end
			case 10: line++; // LF
				#if hscriptPos
				tokenMin++;
				#end
			case "#".code: return THash;
			case _ if(char >= 48 && char <= 57): // 0...9
				var n = (char - 48) * 1.0;
				var exp = 0.;
				while( true ) {
					char = readChar();
					exp *= 10;
					switch( char ) {
					case _ if(char >= 48 && char <= 57):
						n = n * 10 + (char - 48);
					case 46:
						if( exp > 0 ) {
							// in case of '...'
							if( exp == 10 && readChar() == 46 ) {
								push(TOp("..."));
								var i = Std.int(n);
								return TConst( (i == n) ? CInt(i) : CFloat(n) );
							}
							invalidChar(char);
						}
						exp = 1.;
					case 120: // x
						if( n > 0 || exp > 0 )
							invalidChar(char);
						// read hexa
						#if haxe3
						var n = 0;
						while( true ) {
							char = readChar();
							switch( char ) {
							case 48,49,50,51,52,53,54,55,56,57: // 0-9
								n = (n << 4) + char - 48;
							case 65,66,67,68,69,70: // A-F
								n = (n << 4) + (char - 55);
							case 97,98,99,100,101,102: // a-f
								n = (n << 4) + (char - 87);
							default:
								this.char = char;
								return TConst(CInt(n));
							}
						}
						#else
						var n = haxe.Int32.ofInt(0);
						while( true ) {
							char = readChar();
							switch( char ) {
							case 48,49,50,51,52,53,54,55,56,57: // 0-9
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 48));
							case 65,66,67,68,69,70: // A-F
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 55));
							case 97,98,99,100,101,102: // a-f
								n = haxe.Int32.add(haxe.Int32.shl(n,4), cast (char - 87));
							default:
								this.char = char;
								// we allow to parse hexadecimal Int32 in Neko, but when the value will be
								// evaluated by Interpreter, a failure will occur if no Int32 operation is
								// performed
								var v = try CInt(haxe.Int32.toInt(n)) catch( e : Dynamic ) CInt32(n);
								return TConst(v);
							}
						}
						#end
					default:
						this.char = char;
						var i = Std.int(n);
						return TConst( (exp > 0) ? CFloat(n * 10 / exp) : ((i == n) ? CInt(i) : CFloat(n)) );
					}
				}
			case 59: return TSemicolon;
			case 40: return TPOpen;
			case 41: return TPClose;
			case 44: return TComma;
			case 46:
				char = readChar();
				switch( char ) {
				case 48,49,50,51,52,53,54,55,56,57:
					var n = char - 48;
					var exp = 1;
					while( true ) {
						char = readChar();
						exp *= 10;
						switch( char ) {
						case 48,49,50,51,52,53,54,55,56,57:
							n = n * 10 + (char - 48);
						default:
							this.char = char;
							return TConst( CFloat(n/exp) );
						}
					}
				case 46:
					char = readChar();
					if( char != 46 )
						invalidChar(char);
					return TOp("...");
				default:
					this.char = char;
					return TDot;
				}
			case 123: return TBrOpen;
			case 125: return TBrClose;
			case 91: return TBkOpen;
			case 93: return TBkClose;
			case 39: return TInterp(readString(39));
			case 34: return TConst( CString(readString(34)) );
			case 63: return TQuestion;
			case 58: return TDoubleDot;
			default:
				if( ops[char] ) {
					var op = String.fromCharCode(char);
					while( true ) {
						char = readChar();
						if( !ops[char] ) {
							if( op.charCodeAt(0) == 47 )
								return tokenComment(op,char);
							this.char = char;
							return TOp(op);
						}
						op += String.fromCharCode(char);
					}
				}
				if( idents[char] ) {
					var id = String.fromCharCode(char);
					while( true ) {
						char = readChar();
						if( !idents[char] ) {
							this.char = char;
							return TId(id);
						}
						id += String.fromCharCode(char);
					}
				}
				invalidChar(char);
			}
			char = readChar();
		}
		return null;
	}

	function tokenComment( op : String, char : Int ) {
		var c = op.charCodeAt(1);
		var s = input;
		if( c == 47 ) { // comment
			try {
				while( char != 10 && char != 13 ) {
					incPos();
					char = s.readByte();
				}
				this.char = char;
			} catch( e : Dynamic ) {
			}
			return token();
		}
		if( c == 42 ) { /* comment */
			var old = line;
			try {
				while( true ) {
					while( char != 42 ) {
						if( char == 10 ) line++;
						incPos();
						char = s.readByte();
					}
					incPos();
					char = s.readByte();
					if( char == 47 )
						break;
				}
			} catch( e : Dynamic ) {
				line = old;
				error(EUnterminatedComment, tokenMin, tokenMin);
			}
			return token();
		}
		this.char = char;
		return TOp(op);
	}

	function constString( c ) {
		return switch(c) {
		case CInt(v): Std.string(v);
		case CFloat(f): Std.string(f);
		case CString(s): s; // TODO : escape + quote
		#if !haxe3
		case CInt32(v): Std.string(v);
		#end
		}
	}

	function tokenString( t ) {
		return switch( t ) {
			case THash: "#";
			case TEof: "<eof>";
			case TConst(c): constString(c);
			case TId(s): s;
			case TOp(s): s;
			case TPOpen: "(";
			case TPClose: ")";
			case TBrOpen: "{";
			case TBrClose: "}";
			case TDot: ".";
			case TComma: ",";
			case TSemicolon: ";";
			case TBkOpen: "[";
			case TBkClose: "]";
			case TQuestion: "?";
			case TDoubleDot: ":";
			case TInterp(s): "'"+s+"'";
		}
	}
	function parseInterpolatedString(str:String):ExprOf<String> {
		var expr = null;
		function add(e)
			if( expr == null )
				expr = e;
			else
				expr = mk(EBinop("+",expr,e));
		var i = 0, start = 0;
		var max = str.length;
		while( i < max ) {
			if( StringTools.fastCodeAt(str,i++) != '$'.code )
				continue;
			var len = i - start - 1;
			if( len > 0 || expr == null )
				add(mk(EConst(CString(str.substr(start,len)))));
			start = i;
			var c = StringTools.fastCodeAt(str, i);
			if( c == '{'.code ) {
				var count = 1;
				i++;
				while( i < max ) {
					var c = StringTools.fastCodeAt(str,i++);
					if( c == "}".code ) {
					if( --count == 0 ) break;
					} else if( c == "{".code )
					count++;
				}
				if( count > 0 )
					throw "Closing brace not found";
				start++;
				var len = i - start - 1;
				var expr:String = str.substr(start, len);
				add(new Parser().parseString(expr));
				start++;
			} else if( (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code ) {
				i++;
				while( true ) {
					var c = StringTools.fastCodeAt(str, i);
					if( (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code )
					i++;
					else
					break;
				}
				var len = i - start;
				var ident = str.substr(start, len);
				add(mk(EIdent(ident)));
			} else if( c == '$'.code ) {
				start = i++;
				continue;
			} else {
				start = i - 1;
				continue;
			}
			start = i;
		}
		var len = i - start;
		if( len > 0 )
			add(mk(EConst(CString(str.substr(start,len)))));
		if( expr == null )
			expr = mk(EConst(CString("")));
		return expr;
	}
}
