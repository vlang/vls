module vls

import v.ast
import v.table
import v.token

pub type AstNode = ast.Stmt | ast.Expr | ast.StructField | ast.Field | ast.ConstField | ast.StructInitField | ast.GlobalField | ast.EnumField | table.Param

fn (node AstNode) position() token.Position {
	match node {
		ast.Stmt {
			return node.position()
		}
		ast.Expr {
			return node.position()
		}
		ast.StructField,
		ast.Field,
		ast.EnumField,
		ast.ConstField,
		ast.StructInitField,
		ast.GlobalField,
		table.Param {
			return node.pos
		}
	}
}

fn (node AstNode) children() []AstNode {
	if node is ast.Expr {
		match node {
			ast.StringInterLiteral,
			ast.Assoc,
			ast.ArrayInit {
				return node.exprs.map(AstNode(it))
			}
			// ast.SelectorExpr,
			ast.PostfixExpr, 
			ast.UnsafeExpr,
			ast.AsCast,
			ast.ParExpr,
			ast.IfGuardExpr, 
			ast.SizeOf,
			ast.Likely,
			ast.TypeOf {
				return [AstNode(node.expr)]
			}
			ast.LockExpr,
			ast.OrExpr {
				return node.stmts.map(AstNode(it))
			}
			ast.StructInit {
				return node.fields.map(AstNode(it))
			}
			ast.AnonFn {
				return [AstNode(ast.Stmt(node.decl))]
			}
			ast.CallExpr {
				or_block := ast.Expr(node.or_block)
				return [AstNode(node.left), AstNode(or_block)]
			}
			ast.InfixExpr {
				return [AstNode(node.left), AstNode(node.right)]
			}
			ast.PrefixExpr {
				return [AstNode(node.right)]
			}
			ast.IndexExpr {
				return [AstNode(node.left), AstNode(node.index)]
			}
			ast.IfExpr {
				// TODO: include branches
				return [AstNode(node.left)]
			}
			ast.MatchExpr {
				// TODO: include branches
				return [AstNode(node.cond)]
			}
			// SelectExpr {}
			ast.ChanInit {
				return [AstNode(node.cap_expr)]
			}
			ast.MapInit {
				mut children := node.keys.map(AstNode(it))
				children << node.vals.map(AstNode(it))
				return children
			}
			ast.RangeExpr {
				return [AstNode(node.low), AstNode(node.high)]
			}
			ast.CastExpr {
				return [AstNode(node.expr), AstNode(node.arg)]
			}
			ast.ConcatExpr {
				return node.vals.map(AstNode(it))
			}
			else {}
		}
	}

	if node is ast.Stmt {
		match node {
			ast.Block,
			ast.DeferStmt,
			ast.ForCStmt,
			ast.ForInStmt,
			ast.ForStmt,
			ast.CompFor {
				return node.stmts.map(AstNode(it))
			}
			ast.Module,
			ast.ExprStmt,
			ast.AssertStmt {
				return [AstNode(node.expr)]
			}
			ast.InterfaceDecl {
				return node.methods.map(AstNode(ast.Stmt(it)))
			}
			ast.AssignStmt {
				mut children := node.left.map(AstNode(it))
				children << node.right.map(AstNode(it))
				return children
			}
			ast.Return {
				return node.exprs.map(AstNode(it))
			}
			ast.StructDecl {
				return node.fields.map(AstNode(it))
			} 
			ast.GlobalDecl {
				return node.fields.map(AstNode(it))
			} 
			ast.ConstDecl {
				return node.fields.map(AstNode(it))
			} 
			ast.EnumDecl {
				return node.fields.map(AstNode(it))
			}
			ast.FnDecl {
				mut children := []AstNode{}
				if node.is_method {
					children << AstNode(node.receiver)
				}
				children << node.params.map(AstNode(it))
				children << node.stmts.map(AstNode(it))
				return children
			}
			else {}
		}
	}

	match node {
		ast.EnumField,
		ast.GlobalField,
		ast.StructInitField,
		ast.ConstField {
			return [AstNode(node.expr)]
		}
		else {}
	}

	return []AstNode{}
}

pub fn (ls Vls) get_ast_by_pos(line int, col int, source string, nodes []AstNode) ?AstNode {
	for node in nodes {
		mut tok_pos := node.position()
		if node is ast.Stmt {
			if node is ast.Module {
				tok_pos = { tok_pos | len: tok_pos.len + node.name.len }
			}

			if node is ast.Import {
				tok_pos = { tok_pos | pos: tok_pos.pos - 7, len: tok_pos.len + node.mod.len + node.alias.len + 7 }
			}
		} else if node is ast.StructField {
			tok_pos = tok_pos.extend(node.type_pos)
		}

		range := position_to_lsp_range(source, tok_pos)
		if range.start.line == line && (col >= range.start.character && col <= range.end.character) {
			return node
		}
		children := node.children()
		if children.len > 0 {
			child_ast := ls.get_ast_by_pos(line, col, source, children) or { 
				continue
			}
			return child_ast
		}
	}

	return error('not found')
}