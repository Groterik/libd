module d.semantic.identifier;

import d.semantic.semantic;

import d.ast.dmodule;
import d.ast.identifier;

import d.ir.dscope;
import d.ir.expression;
import d.ir.symbol;
import d.ir.type;

import d.context;
import d.exception;
import d.location;

import std.algorithm;
import std.array;

alias Module = d.ir.symbol.Module;

alias SymbolResolver(alias handler) = IdentifierResolver!(handler, false);
alias AliasResolver(alias handler)  = IdentifierResolver!(handler, true);

alias SymbolPostProcessor(alias handler) = IdentifierPostProcessor!(handler, false);
alias AliasPostProcessor(alias handler)  = IdentifierPostProcessor!(handler, true);

/**
 * Resolve identifier!(arguments).identifier as type or expression.
 */
struct TemplateDotIdentifierResolver(alias handler) {
	private SemanticPass pass;
	alias pass this;
	
	alias Ret = typeof(handler(Symbol.init));
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	Ret resolve(TemplateInstanciationDotIdentifier i, Expression[] fargs = []) {
		import d.semantic.dtemplate : TemplateInstancier, TemplateArgument;
		auto args = i.templateInstanciation.arguments.map!((a) {
			if(auto ia = cast(IdentifierTemplateArgument) a) {
				return AliasResolver!identifiableHandler(pass)
					.visit(ia.identifier)
					.apply!((identified) {
						static if(is(typeof(identified) : Expression)) {
							return TemplateArgument(pass.evaluate(identified));
						} else {
							return TemplateArgument(identified);
						}
					})();
			} else if(auto ta = cast(TypeTemplateArgument) a) {
				import d.semantic.type;
				return TemplateArgument(TypeVisitor(pass).visit(ta.type));
			} else if(auto va = cast(ValueTemplateArgument) a) {
				import d.semantic.expression;
				return TemplateArgument(pass.evaluate(ExpressionVisitor(pass).visit(va.value)));
			}
			
			assert(0, typeid(a).toString() ~ " is not supported.");
		}).array();
		
		// XXX: identifiableHandler shouldn't be necessary, we should pas a free function.
		auto instance = SymbolResolver!identifiableHandler(pass).visit(i.templateInstanciation.identifier).apply!((identified) {
			static if(is(typeof(identified) : Symbol)) {
				if(auto t = cast(Template) identified) {
					return TemplateInstancier(pass).instanciate(i.templateInstanciation.location, t, args, fargs);
				} else if(auto s = cast(OverloadSet) identified) {
					return TemplateInstancier(pass).instanciate(i.templateInstanciation.location, s, args, fargs);
				}
			}
			
			return cast(TemplateInstance) null;
		})();
		
		assert(instance);
		scheduler.require(instance, Step.Populated);
		
		if(auto s = instance.dscope.resolve(i.name)) {
			return SymbolPostProcessor!handler(pass, i.location).visit(s);
		}
		
		// Let's try eponymous trick if the previous failed.
		auto name = i.templateInstanciation.identifier.name;
		if(name != i.name) {
			if(auto s = instance.dscope.resolve(name)) {
				return SymbolResolver!identifiableHandler(pass).resolveInSymbol(i.location, s, i.name).apply!handler();
			}
		}
		
		throw new CompileException(i.location, i.name.toString(context) ~ " not found in template");
	}
}

private:
enum Tag {
	Symbol,
	Expression,
	Type,
}

struct Identifiable {
	union {
		Symbol sym;
		Expression expr;
		Type type;
	}
	
	import d.ast.base : TypeQualifier;
	
	import std.bitmanip;
	mixin(bitfields!(
		Tag, "tag", 2,
		TypeQualifier, "qual", 3,
		uint, "", 3,
	));
	
	@disable this();
	
	this(Identifiable i) {
		this = i;
	}
	
	this(Symbol s) {
		tag = Tag.Symbol;
		sym = s;
	}
	
	this(Expression e) {
		tag = Tag.Expression;
		expr = e;
	}
	
	this(QualType qt) {
		tag = Tag.Type;
		qual = qt.qualifier;
		type = qt.type;
	}
	
	// TODO: add invariant when possible.
	// bitfield cause infinite recursion now.
}

// XXX: probably a "feature" this can't be passed as alias this if private.
public
Identifiable identifiableHandler(T)(T t) {
	return Identifiable(t);
}

auto apply(alias handler)(Identifiable i) {
	final switch(i.tag) with(Tag) {
		case Symbol :
			return handler(i.sym);
		
		case Expression :
			return handler(i.expr);
		
		case Type :
			return handler(QualType(i.type, i.qual));
	}
}

/**
 * General entry point to resolve identifiers.
 */
struct IdentifierResolver(alias handler, bool asAlias) {
	private SemanticPass pass;
	alias pass this;
	
	alias Ret = typeof(handler(Symbol.init));
	alias SelfPostProcessor = IdentifierPostProcessor!(handler, asAlias);
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	Ret visit(Identifier i) {
		return this.dispatch(i);
	}
	
	private Symbol resolveImportedSymbol(Location location, Name name) {
		auto dscope = currentScope;
		
		while(true) {
			Symbol symbol;
			
			foreach(m; dscope.imports) {
				scheduler.require(m, Step.Populated);
				
				auto symInMod = m.dscope.resolve(name);
				if(symInMod) {
					if(symbol) {
						return pass.raiseCondition!Symbol(location, "Ambiguous symbol " ~ name.toString(context) ~ ".");
					}
					
					symbol = symInMod;
				}
			}
			
			if(symbol) return symbol;
			
			if(auto nested = cast(NestedScope) dscope) {
				dscope = nested.parent;
			} else {
				return pass.raiseCondition!Symbol(location, "Symbol " ~ name.toString(context) ~ " has not been found.");
			}
			
			if(auto sscope = cast(SymbolScope) dscope) {
				scheduler.require(sscope.symbol, Step.Populated);
			}
		}
	}
	
	private Symbol resolveName(Location location, Name name) {
		auto symbol = currentScope.search(name);
		
		// I wish we had ?:
		return symbol ? symbol : resolveImportedSymbol(location, name);
	}
	
	Ret visit(BasicIdentifier i) {
		return SelfPostProcessor(pass, i.location).visit(resolveName(i.location, i.name));
	}
	
	Ret visit(IdentifierDotIdentifier i) {
		return resolveInIdentifiable(i.location, SymbolResolver!identifiableHandler(pass).visit(i.identifier), i.name);
	}
	
	Ret resolveInType(Location location, QualType t, Name name) {
		return TypeDotIdentifierResolver!((identified) {
			alias T = typeof(identified);
			static if(is(T : Symbol)) {
				return SelfPostProcessor(pass, location).visit(identified);
			} else {
				return handler(identified);
			}
		})(pass, location, name).visit(t);
	}
	
	Ret resolveInExpression(Location location, Expression e, Name name) {
		return ExpressionDotIdentifierResolver!handler(pass, location, e).resolve(name);
	}
	
	// XXX: higly dubious, see how this can be removed.
	Ret resolveInSymbol(Location location, Symbol s, Name name) {
		return resolveInIdentifiable(location, SymbolPostProcessor!identifiableHandler(pass, location).visit(s), name);
	}
	
	private Ret resolveInIdentifiable(Location location, Identifiable i, Name name) {
		return i.apply!(delegate Ret(identified) {
			alias T = typeof(identified);
			static if(is(T : QualType)) {
				return resolveInType(location, identified, name);
			} else static if(is(T : Expression)) {
				return resolveInExpression(location, identified, name);
			} else {
				pass.scheduler.require(identified, pass.Step.Populated);
				auto spp = SelfPostProcessor(pass, location);
				
				if(auto i = cast(TemplateInstance) identified) {
					return spp.visit(i.dscope.resolve(name));
				} else if(auto m = cast(Module) identified) {
					return spp.visit(m.dscope.resolve(name));
				}
				
				throw new CompileException(location, "Can't resolve " ~ name.toString(pass.context));
			}
		})();
	}
	
	Ret visit(ExpressionDotIdentifier i) {
		import d.semantic.expression;
		return resolveInExpression(i.location, ExpressionVisitor(pass).visit(i.expression), i.name);
	}
	
	Ret visit(TypeDotIdentifier i) {
		import d.semantic.type;
		return resolveInType(i.location, TypeVisitor(pass).visit(i.type), i.name);
	}
	
	Ret visit(TemplateInstanciationDotIdentifier i) {
		return TemplateDotIdentifierResolver!handler(pass).resolve(i);
	}
	
	Ret visit(IdentifierBracketIdentifier i) {
		return SymbolResolver!identifiableHandler(pass).visit(i.indexed).apply!(delegate Ret(indexed) {
			alias T = typeof(indexed);
			static if(is(T : QualType)) {
				return SymbolResolver!identifiableHandler(pass).visit(i.index).apply!(delegate Ret(index) {
					alias U = typeof(index);
					static if(is(U : QualType)) {
						assert(0, "AA are not implemented");
					} else static if(is(U : Expression)) {
						// XXX: dedup with IdentifierBracketExpression
						import d.semantic.caster, d.semantic.expression;
						auto se = buildImplicitCast(pass, i.index.location, pass.object.getSizeT().type, index);
						return handler(QualType(new ArrayType(indexed, pass.evalIntegral(se))));
					} else {
						assert(0, "Add meaningful error message.");
					}
				})();
			} else static if(is(T : Expression)) {
				return SymbolResolver!identifiableHandler(pass).visit(i.index).apply!(delegate Ret(index) {
					alias U = typeof(index);
					static if(is(U : Expression)) {
						import d.semantic.expression;
						return handler(ExpressionVisitor(pass).getIndex(i.location, indexed, index));
					} else {
						assert(0, "Add meaningful error message.");
					}
				})();
			} else {
				assert(0, "Add meaningful error message.");
			}
		})();
	}
	
	Ret visit(IdentifierBracketExpression i) {
		return SymbolResolver!identifiableHandler(pass).visit(i.indexed).apply!(delegate Ret(identified) {
			alias T = typeof(identified);
			static if(is(T : QualType)) {
				// XXX: dedup with IdentifierBracketExpression
				import d.semantic.caster, d.semantic.expression;
				auto se = buildImplicitCast(pass, i.index.location, pass.object.getSizeT().type, ExpressionVisitor(pass).visit(i.index));
				return handler(QualType(new ArrayType(identified, pass.evalIntegral(se))));
			} else static if(is(T : Expression)) {
				import d.semantic.expression;
				return handler(ExpressionVisitor(pass).getIndex(i.location, identified, ExpressionVisitor(pass).visit(i.index)));
			} else {
				assert(0, "It seems some weird index expression");
			}
		})();
	}
}

/**
 * Post process resolved identifiers.
 */
struct IdentifierPostProcessor(alias handler, bool asAlias) {
	private SemanticPass pass;
	alias pass this;
	
	alias Ret = typeof(handler(Symbol.init));
	
	private Location location;
	
	this(SemanticPass pass, Location location) {
		this.pass = pass;
		this.location = location;
	}
	
	Ret visit(Symbol s) {
		return this.dispatch(s);
	}
	
	Ret visit(TypeSymbol s) {
		return this.dispatch(s);
	}
	
	Ret visit(ValueSymbol s) {
		return this.dispatch(s);
	}
	
	Ret visit(Function f) {
		static if(asAlias) {
			return handler(f);
		} else {
			import d.semantic.expression;
			return handler(ExpressionVisitor(pass).getFrom(location, f));
		}
	}
	
	Ret visit(Method m) {
		return visit(cast(Function) m);
	}
	
	Ret visit(Variable v) {
		static if(asAlias) {
			return handler(v);
		} else {
			scheduler.require(v, Step.Signed);
			return handler(new VariableExpression(location, v));
		}
	}
	
	Ret visit(Field f) {
		scheduler.require(f, Step.Signed);
		return handler(new FieldExpression(location, new ThisExpression(location, QualType(thisType.type)), f));
	}
	
	Ret visit(ValueAlias a) {
		static if(asAlias) {
			return handler(a);
		} else {
			scheduler.require(a, Step.Signed);
			return handler(a.value);
		}
	}
	
	Ret visit(OverloadSet s) {
		if(s.set.length == 1) {
			return visit(s.set[0]);
		}
		
		return handler(s);
	}
	
	Ret visit(SymbolAlias s) {
		scheduler.require(s, Step.Signed);
		return visit(s.symbol);
	}
	
	private auto getSymbolType(T, S)(S s) {
		static if(asAlias) {
			return handler(s);
		} else {
			return handler(QualType(new T(s)));
		}
	}
	
	Ret visit(TypeAlias a) {
		// XXX: get rid of peelAlias and then get rid of this.
		scheduler.require(a);
		return getSymbolType!AliasType(a);
	}
	
	Ret visit(Struct s) {
		return getSymbolType!StructType(s);
	}
	
	Ret visit(Class c) {
		return getSymbolType!ClassType(c);
	}
	
	Ret visit(Enum e) {
		return getSymbolType!EnumType(e);
	}
	
	Ret visit(Template t) {
		return handler(t);
	}
	
	Ret visit(TemplateInstance i) {
		return handler(i);
	}
	
	Ret visit(Module m) {
		return handler(m);
	}
	
	Ret visit(TypeTemplateParameter t) {
		import d.ir.dtemplate;
		return getSymbolType!TemplatedType(t);
	}
}

/**
 * Resolve expression.identifier as type or expression.
 */
struct ExpressionDotIdentifierResolver(alias handler) {
	SemanticPass pass;
	alias pass this;
	
	alias Ret = typeof(handler(Symbol.init));
	
	Location location;
	Expression expr;
	
	this(SemanticPass pass, Location location, Expression expr) {
		this.pass = pass;
		this.location = location;
		this.expr = expr;
	}
	
	Ret resolve(Name name) {
		auto type = expr.type;
		return TypeDotIdentifierResolver!(delegate Ret(identified) {
			alias T = typeof(identified);
			static if (is(T : Symbol)) {
				// XXX: I'd like to have a more elegant way to retrive this.
				return visit(identified);
			} else if (is(T : Expression)) {
				// sizeof, init and other goodies.
				return handler(new BinaryExpression(location, identified.type, BinaryOp.Comma, expr, identified));
			} else {
				assert(0, "expression.type not implemented");
			}
		}, delegate Ret(r, t) {
			alias T = typeof(t);
			static if (is(T : StructType) || is(T : ClassType)) {
				import d.semantic.aliasthis;
				auto candidates = AliasThisResolver!identifiableHandler(pass).resolve(expr, t);
				
				Ret[] results;
				foreach(c; candidates) {
					// TODO: refactor so we do not throw.
					try {
						results ~= SymbolResolver!identifiableHandler(pass)
							.resolveInIdentifiable(location, c, name)
							.apply!handler();
					} catch(CompileException e) {
						continue;
					}
				}
				
				if (results.length == 1) {
					return results[0];
				} else if (results.length > 1) {
					assert(0, "WTF am I supposed to do here ?");
				}
			}
			
			// UFCS
			try {
				auto oldBuildErrorNode = pass.buildErrorNode;
				scope(exit) pass.buildErrorNode = oldBuildErrorNode;
				
				pass.buildErrorNode = false;
				return visit(AliasResolver!identifiableHandler(pass).resolveName(location, name));
			} catch(CompileException e) {}
			
			static if(is(T : PointerType)) {
				expr = new UnaryExpression(expr.location, t.pointed, UnaryOp.Dereference, expr);
				return r.visit(t.pointed);
			} else {
				return r.bailoutDefault(type.type);
			}
		})(pass, location, name).visit(type);
	}
	
	Ret visit(Symbol s) {
		return this.dispatch!((s) {
			throw new CompileException(s.location, "Don't know how to dispatch " ~ typeid(s).toString());
		})(s);
	}
	
	Ret visit(OverloadSet s) {
		if(s.set.length == 1) {
			return visit(s.set[0]);
		}
		
		Expression[] exprs;
		foreach (sym; s.set) {
			try {
				if(auto f = cast(Function) sym) {
					exprs ~= makeExpression(f);
				} else {
					assert(0, "not implemented: template with context");
				}
			} catch(CompileException e) {}
		}
		
		switch(exprs.length) {
			case 0 :
				throw new CompileException(location, "No valid candidate in overload set");
			
			case 1 :
				return handler(exprs[0]);
			
			default :
				return handler(new PolysemousExpression(location, exprs));
		}
	}
	
	Ret visit(Field f) {
		scheduler.require(f, Step.Signed);
		return handler(new FieldExpression(location, expr, f));
	}
	
	// XXX: dedup with ExpressionVisitor
	private Expression makeExpression(Function f) {
		scheduler.require(f, Step.Signed);
		
		import d.semantic.expression;
		auto arg = ExpressionVisitor(pass).buildArgument(expr, f.type.paramTypes[0]);
		auto e = new MethodExpression(location, arg, f);
		
		// If this is not a property, things are straigforward.
		if (!f.isProperty) {
			return e;
		}
		
		switch(f.params.length - f.hasContext) {
			case 1:
				return new CallExpression(location, QualType(f.type.returnType.type, f.type.returnType.qualifier), e, []);
			
			case 2:
				assert(0, "setter not supported)");
			
			default:
				assert(0, "Invalid argument count for property " ~ f.name.toString(context));
		}
	}
	
	Ret visit(Function f) {
		return handler(makeExpression(f));
	}
	
	Ret visit(Method m) {
		return handler(makeExpression(m));
	}
	
	Ret visit(TypeAlias a) {
		// XXX: get rid of peelAlias and then get rid of this.
		scheduler.require(a);
		return handler(QualType(new AliasType(a)));
	}
	
	Ret visit(Struct s) {
		return handler(QualType(new StructType(s)));
	}
	
	Ret visit(Class c) {
		return handler(QualType(new ClassType(c)));
	}
	
	Ret visit(Enum e) {
		return handler(QualType(new EnumType(e)));
	}
}

/**
 * Resolve symbols in types.
 */
struct TypeDotIdentifierResolver(alias handler, alias bailoutOverride = null) {
	SemanticPass pass;
	alias pass this;
	
	alias Ret = typeof(handler(Symbol.init));
	
	Location location;
	Name name;
	
	this(SemanticPass pass, Location location, Name name) {
		this.pass = pass;
		this.location = location;
		this.name = name;
	}
	
	enum hasBailoutOverride = !is(typeof(bailoutOverride) : typeof(null));
	
	Ret bailout(T)(T t) if(is(T : Type)) {
		static if (hasBailoutOverride) {
			 return bailoutOverride(this, t);
		} else {
			return bailoutDefault(t);
		}
	}
	
	Ret bailoutDefault(Type t) {
		if(name == BuiltinName!"init") {
			import d.semantic.defaultinitializer;
			return handler(InitBuilder(pass, location).visit(QualType(t)));
		} else if(name == BuiltinName!"sizeof") {
			import d.semantic.sizeof;
			return handler(new IntegerLiteral!false(location, SizeofVisitor(pass).visit(t), TypeKind.Uint));
		}
	
		throw new CompileException(location, name.toString(context) ~ " can't be resolved in type " ~ t.toString(context));
	}
	
	Ret visit(QualType qt) {
		return this.dispatch!(t => bailout(t))(qt.type);
	}

	Ret visit(ArrayType t) {
		if(name == BuiltinName!"length") {
			auto sizeT = cast(BuiltinType) peelAlias(pass.object.getSizeT().type).type;
			assert(sizeT !is null);
			auto s = new IntegerLiteral!false(location, t.size, sizeT.kind);
			return handler(s);
		}

		return bailout(t);
	}

	Ret visit(BuiltinType t) {
		if (name == BuiltinName!"max") {
			if (t.kind == TypeKind.Bool) {
				return handler(new BooleanLiteral(location, true));
			} else if (isIntegral(t.kind)) {
				if (isSigned(t.kind)) {
					return handler(new IntegerLiteral!true(location, getMax(t), t.kind));
				} else {
					return handler(new IntegerLiteral!false(location, getMax(t), t.kind));
				}
			}
		} else if (name == BuiltinName!"min") {
			if (t.kind == TypeKind.Bool) {
				return handler(new BooleanLiteral(location, false));
			} else if (isIntegral(t.kind)) {
				if (isSigned(t.kind)) {
					return handler(new IntegerLiteral!true(location, getMin(t), t.kind));
				} else {
					return handler(new IntegerLiteral!false(location, getMin(t), t.kind));
				}
			}
		}
		
		return bailout(t);
	}

	Ret visit(SliceType t) {
		if(name == BuiltinName!"length") {
			// FIXME: pass explicit location.
			auto location = Location.init;
			auto lt = pass.object.getSizeT().type;
			auto s = new Field(location, 0, lt, BuiltinName!"length", null);
			s.step = Step.Processed;
			return handler(s);
		} else if(name == BuiltinName!"ptr") {
			// FIXME: pass explicit location.
			auto location = Location.init;
			auto pt = QualType(new PointerType(t.sliced));
			auto s = new Field(location, 1, pt, BuiltinName!"ptr", null);
			s.step = Step.Processed;
			return handler(s);
		}
		
		return bailout(t);
	}
	
	Ret visit(AliasType t) {
		auto a = t.dalias;
		scheduler.require(a, Step.Populated);
		
		return visit(t.dalias.type);
	}
	
	Ret visit(StructType t) {
		auto s = t.dstruct;
		
		scheduler.require(s, Step.Populated);
		if(auto sym = s.dscope.resolve(name)) {
			return handler(sym);
		}
		
		return bailout(t);
	}
	
	Ret visit(ClassType t) {
		return visit(t.dclass);
	}
	
	Ret visit(Class c) {
		scheduler.require(c, Step.Populated);
		if(auto s = c.dscope.resolve(name)) {
			return handler(s);
		}
		
		if (c !is c.base) {
			// XXX: check if the compiler is smart enough to make a loop out of this.
			static if (hasBailoutOverride) {
				return TypeDotIdentifierResolver!handler(pass, location, name).visit(c.base);
			} else {
				return visit(c.base);
			}
		}
		
		return bailout(new ClassType(c));
	}
	
	Ret visit(EnumType t) {
		auto e = t.denum;
		scheduler.require(e, Step.Populated);
		
		if (auto s = e.dscope.resolve(name)) {
			return handler(s);
		}
		
		return visit(QualType(t.denum.type));
	}
	
	Ret visit(PointerType t) {
		return bailout(t);
	}
}

