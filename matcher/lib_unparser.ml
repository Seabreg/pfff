(* Yoann Padioleau
 * 
 * Copyright (C) 2013 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

module PI = Parse_info
open Parse_info

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * There are multiple ways to unparse code:
 *  - one can iterate over an AST (or better CST), and print its leaves, but 
 *    comments and spaces are usually not in the CST (and for a good reason)
 *    so you need  some extra code that also visits the tokens and try 
 *    to "sync" the visit of the CST with the tokens
 *  - one can use a real pretty printer with a boxing or backtracking model
 *    working on an AST extended with comments (see julien's ast_pretty_print/)
 *  - one can iterate over the tokens, where comments and spaces are normal
 *    citizens, but this can be too low level
 * 
 * Right now the preferred method for spatch is the last one. The pretty
 * printer currently is too different from our coding conventions
 * (also because we don't have precise coding conventions).
 * This token-based unparser handles transformation annotations (Add/Remove).
 * This was also the approach used in Coccinelle.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* Intermediate representations easier to work on; more convenient to
 * program heuristics which try to maintain some good indentation
 * and style.
 *)
type elt =
 | OrigElt of string
 | Removed of string
 | Added of string
 | Esthet of esthet
 and esthet =
  | Comment of string
  | Newline
  | Space of string
 (* with tarzan *)

(*****************************************************************************)
(* Globals *)
(*****************************************************************************)

let debug = ref false

(*****************************************************************************)
(* Vof *)
(*****************************************************************************)

(* autogenerated by ocamltarzan *)
let rec vof_elt =
  function
  | OrigElt v1 ->
      let v1 = Ocaml.vof_string v1 in Ocaml.VSum (("OrigElt", [ v1 ]))
  | Removed v1 -> 
      let v1 = Ocaml.vof_string v1 in Ocaml.VSum (("Removed", [ v1 ]))
  | Added v1 ->
      let v1 = Ocaml.vof_string v1 in Ocaml.VSum (("Added", [ v1 ]))
  | Esthet v1 -> let v1 = vof_esthet v1 in Ocaml.VSum (("Esthet", [ v1 ]))
and vof_esthet =
  function
  | Comment v1 ->
      let v1 = Ocaml.vof_string v1 in Ocaml.VSum (("Comment", [ v1 ]))
  | Newline -> Ocaml.VSum (("Newline", []))
  | Space v1 ->
      let v1 = Ocaml.vof_string v1 in Ocaml.VSum (("Space", [ v1 ]))

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let s_of_add = function
  | AddStr s -> s
  | AddNewlineAndIdent -> raise Todo

(* rh = reversed head, tl = tail *)
let rec add_if_need_comma add_str rh tl =
  match tl with
  (* Because this token is right parenthese, there must be
     something before*)
  | [] -> failwith "Error with need_comma"
  | (OrigElt str)::t when ((str = ",") || (str = "(")) ->
    List.rev_append rh tl
  | ((OrigElt str) as h)::t ->
    List.rev_append rh ((Added add_str)::h::t)
  | ((Removed str) as h)::t -> add_if_need_comma add_str (h::rh) t
  (* Added is very arbitrary, I'd rather not handle them.
   * This can be avoided by using AddArgsBefore only
   *)
  | (Added str)::t ->
    failwith "need comma: cannot handle this case!"
  | ((Esthet _) as h)::t -> add_if_need_comma add_str (h::rh) t

let rec search_prev_elt ?(ws=0) acc =
  match acc with
  (* Because this token is right parenthese, there must be
     something before *)
  | [] -> failwith "Error with search_prev_real_elt"
  | (OrigElt str)::t -> (OrigElt str, ws)
  | (Removed str)::t -> search_prev_elt ~ws t
  | (Added str)::t ->
    failwith "search_prev_real_elt: cannot handle this case"
  | (Esthet(Comment str))::t -> search_prev_elt ~ws t
  | (Esthet Newline)::t -> (Esthet Newline, ws) 
  | (Esthet(Space str))::t ->
    search_prev_elt ~ws:(ws + String.length str) t


(* This function decides how to add arguments. 
 * factors considered:
 * prepend/append comma around arguments?
 * new line for each argument?
 * heuristic:
 * if previous (real) token is '(' or ',', do not prepend comma
 * if this token (right parenthese) follows a newline and some space, add newline for
 * each argument, and append a comma
*)
let elts_of_add_args_before acc xs =
  let (elt, ws) = search_prev_elt acc in
  (* search_prev_elt will fail if meet Added, which may be inserted
  during add_if_need_comma.
  *)
  if (elt = (Esthet Newline))
  (* new line for each argument *)
  then
    let acc = add_if_need_comma "," [] acc in
    let sep = xs +> List.map (fun s ->
      "  " ^ s ^ ",\n" ^ String.make ws ' ') in
    let add_str = join "" sep in
    (Added add_str)::acc
  else
    let acc = add_if_need_comma ", " [] acc in
    let add_str = join ", " xs in
    (Added add_str)::acc

let rec elts_of_any ~elt_and_info_of_tok acc toks =
  match toks with
  | [] -> List.rev acc
  | tok::t -> (
    let elt, info = elt_and_info_of_tok tok in
    match info.token with
    | Ab | FakeTokStr _ | ExpandedTok _ -> raise Impossible
    | OriginTok _ -> 
      (match info.transfo with
      (* acc is reversed! *)
      | NoTransfo -> elts_of_any ~elt_and_info_of_tok (elt::acc) t
      | Remove -> 
        elts_of_any ~elt_and_info_of_tok (Removed (PI.str_of_info info)::acc) t
      (* could also be [Added; Removed], but because of heuristics like
       * drop_esthet_between_removed, when people use Replace, they
       * usually prefers this behavior.
       * todo: it actually causes tests/php/spatch/distr_plus.spatch to
       * have a bad spacing
       *)
      | Replace toadd -> 
        elts_of_any ~elt_and_info_of_tok 
          (Added (s_of_add toadd)::Removed (PI.str_of_info info)::acc) t
      | AddAfter toadd -> 
        elts_of_any ~elt_and_info_of_tok 
          (Added (s_of_add toadd)::elt::acc) t
      | AddBefore toadd -> 
        elts_of_any ~elt_and_info_of_tok 
          (elt::Added (s_of_add toadd)::acc) t
      | AddArgsBefore xs ->
        let elt_list = elts_of_add_args_before acc xs in
        let acc = elt::elt_list in
        elts_of_any ~elt_and_info_of_tok acc t
      )
  )

(*****************************************************************************)
(* Heuristics *)
(*****************************************************************************)

(* but needs to keep the Removed, otherwise drop_whole_line_if_only_removed()
 * can not know which new empty lines it has to remove
 *)
let drop_esthet_between_removed xs =
  let rec outside_remove = function
    | [] -> []
    | Removed s::xs -> Removed s:: in_remove [] xs
    | x::xs -> x::outside_remove xs
  and in_remove acc = function
    | [] -> List.rev acc
    | Removed s::xs -> Removed s::in_remove [] xs
    | Esthet x::xs -> in_remove (Esthet x::acc) xs
    | Added s::xs -> List.rev (Added s::acc) ++ outside_remove xs
    | OrigElt s::xs -> List.rev (OrigElt s::acc) ++ outside_remove xs 
  in
  outside_remove xs

(* note that it will also remove comments in the line if everthing else
 * was removed, which is what we want most of the time
 *)
let drop_whole_line_if_only_removed xs =
  let (before_first_newline, xxs) = xs +> Common2.group_by_pre (function
    | Esthet Newline -> true | _ -> false)
  in
  let xxs = xxs +> Common.exclude (fun (newline, elts_after_newline) ->
    let has_a_remove = 
      elts_after_newline +> List.exists (function 
      | Removed _ -> true | _ -> false) in
    let only_remove_or_esthet = 
      elts_after_newline +> List.for_all (function
      | Esthet _ | Removed _ -> true
      | Added _ | OrigElt _ -> false
      )
    in
    has_a_remove && only_remove_or_esthet
  )
  in
  before_first_newline ++ 
    (xxs +> List.map (fun (elt, elts) -> elt::elts) +> List.flatten)

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

(* 
 * The idea of the algorithm below is to iterate over all the tokens
 * and depending on the token 'transfo' annotation to print or not
 * the token as well as the comments/spaces associated with the token.
 * Note that if two tokens were annotated with a Remove, we
 * also want to remove the spaces between so we need a few heuristics
 * to maintain some good style.
 *)
let string_of_toks_using_transfo ~elt_and_info_of_tok toks =

  let elts_of_tok tok =
    elts_of_any ~elt_and_info_of_tok tok
  in

  Common2.with_open_stringbuf (fun (_pr_with_nl, buf) ->
    let pp s = Buffer.add_string buf s in

    let xs = elts_of_tok [] toks in

    if !debug 
    then xs +> List.iter (fun x -> 
      pr2 (Ocaml.string_of_v (vof_elt x))
    );
    let xs = drop_esthet_between_removed xs in
    let xs = drop_whole_line_if_only_removed xs in
    
    xs +> List.iter (function
    | OrigElt s | Added s | Esthet (Comment s | Space s) -> pp s
    | Removed _ -> ()
    | Esthet Newline -> pp "\n"
    )
  )
