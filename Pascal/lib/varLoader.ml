(** Copyright 2021-2022, Kazancev Anton *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open Ast
open Exceptions
open Eval
open VTypeBasics

let load_variables : define list -> world =
 fun def ->
  let rec load_variables_in def w =
    let var v = VVariable v in
    let const v = VConst v in
    let tp = VType in
    let def_to_world w =
      let eval_expr e = eval_expr_const e w in
      let rec vtype : ptype -> vtype =
       fun t ->
        let rec eval = function
          | PTBool -> VTBool
          | PTInt -> VTInt
          | PTFloat -> VTFloat
          | PTChar -> VTChar
          | PTVoid -> VTVoid
          | PTDString e ->
            VTString
              (match eval_expr e with
               | VInt i when i > 0 -> i
               | _ -> raise (PascalInterp TypeError))
          | PTString -> VTString 255
          | PTRecord l ->
            let list_to_map =
              let add_to_map w (n, t) =
                match w with
                | w when not (KeyMap.mem n w) -> KeyMap.add n (vtype t) w
                | _ -> raise (PascalInterp (DupVarName n))
              in
              List.fold_left add_to_map KeyMap.empty
            in
            VTDRecord (list_to_map l)
          | PTFunction (p, t) -> VTFunction (vtype_fun_param p, vtype t)
          | PTArray (e1, e2, t) ->
            let v1 = eval_expr e1 in
            let v2 = eval_expr e2 in
            let size = iter_arr v1 v2 + 1 in
            VTArray (v1, size, eval t)
          | PTCustom n ->
            (match Worlds.load n w with
             | t, VType -> t
             | _ -> raise (PascalInterp (NotAType n)))
        in
        match eval t with
        | VTString i as s when i > 0 -> s
        | VTString _ -> raise (PascalInterp TypeError)
        | VTArray ((VChar _ | VInt _ | VBool _), s, _) as arr when s > 0 -> arr
        | VTArray _ -> raise (PascalInterp TypeError)
        | ok -> ok
      and vtype_fun_param pl =
        List.map
          (function
           | FPFree (n, t) -> FPFree (n, vtype t)
           | FPOut (n, t) -> FPOut (n, vtype t)
           | FPConst (n, t) -> FPConst (n, vtype t))
          pl
      in
      let rec construct = function
        | VTBool -> VBool false
        | VTInt -> VInt 0
        | VTFloat -> VFloat 0.
        | VTChar -> VChar (Char.chr 0)
        | VTString _ -> VString ""
        | VTDRecord w -> VRecord (KeyMap.map (fun t -> t, VVariable (construct t)) w)
        | VTFunction _ -> VVoid
        | VTArray (v, s, t) -> VArray (v, s, t, ImArray.make s (construct t))
        | _ -> VVoid
      in
      function
      | DType (n, t) ->
        let t = vtype t in
        n, (t, tp)
      | DNDVariable (n, t) ->
        let t = vtype t in
        n, (t, var (construct t))
      | DVariable (n, t, e) ->
        let t = vtype t in
        n, (t, var (eval_expr e))
      | DDVariable (n, t, v) ->
        let t = vtype t in
        n, (t, var v)
      | DConst (n, e) ->
        let v = eval_expr e in
        n, (get_type_val v, const v)
      | DDConst (n, v) -> n, (get_type_val v, const v)
      | DFunction (n, t, p, (d, c)) ->
        let t = vtype t in
        let fun_param_def =
          List.map
            (function
             | FPFree (n, t) | FPOut (n, t) -> DNDVariable (n, t)
             | FPConst (n, t) -> DDConst (n, construct (vtype t)))
            p
        in
        let p = vtype_fun_param p in
        let fdef = fun_param_def @ d in
        let fw = load_variables_in fdef (KeyMap.empty :: w) in
        let fw =
          if KeyMap.mem n fw
          then raise (PascalInterp (DupVarName n))
          else KeyMap.add n (t, VFunctionResult (construct t)) fw
        in
        n, (VTFunction (p, t), const (VFunction (n, t, p, fw, c)))
    in
    let add_to_world w d =
      let name, value = def_to_world w d in
      match w with
      | [] -> [ KeyMap.add name value KeyMap.empty ]
      | h :: _ when KeyMap.mem name h -> raise (PascalInterp (DupVarName name))
      | h :: tl -> KeyMap.add name value h :: tl
    in
    match List.fold_left (fun w d -> add_to_world w d) w def with
    | [] -> KeyMap.empty
    | h :: _ -> h
  in
  load_variables_in def [ KeyMap.empty ]
;;

let%test "load variables test" =
  let rec world_cmp x y =
    match x, y with
    | ( (xft, VConst (VFunction (xn, xt, xpl, xw, xstmt)))
      , (yft, VConst (VFunction (yn, yt, ypl, yw, ystmt))) )
      when compare_types xft yft
           && xn = yn
           && compare_types xt yt
           && xpl = ypl
           && xstmt = ystmt -> KeyMap.equal world_cmp xw yw
    | x, y -> x = y
  in
  KeyMap.equal
    world_cmp
    (load_variables
       [ DConst ("n", BinOp (Add, Const (VInt 2), Const (VInt 2)))
       ; DNDVariable ("a", PTArray (Const (VInt 0), Variable "n", PTBool))
       ; DFunction
           ( "f"
           , PTBool
           , []
           , ( [ DNDVariable ("a", PTArray (Const (VInt 0), Variable "n", PTBool))
               ; DConst ("n", BinOp (Add, Const (VInt 5), Variable "n"))
               ; DFunction
                   ( "ff"
                   , PTBool
                   , []
                   , ( [ DNDVariable ("a", PTArray (Const (VInt 0), Variable "n", PTBool))
                       ]
                     , [] ) )
               ]
             , [] ) )
       ; DConst ("nn", Variable "n")
       ])
    (KeyMap.of_seq
       (List.to_seq
          [ "n", (VTInt, VConst (VInt 4))
          ; ( "a"
            , ( VTArray (VInt 0, 5, VTBool)
              , VVariable (VArray (VInt 0, 5, VTBool, ImArray.make 5 (VBool false))) ) )
          ; ( "f"
            , ( VTFunction ([], VTBool)
              , VConst
                  (VFunction
                     ( "f"
                     , VTBool
                     , []
                     , KeyMap.of_seq
                         (List.to_seq
                            [ "f", (VTBool, VFunctionResult (VBool false))
                            ; ( "a"
                              , ( VTArray (VInt 0, 5, VTBool)
                                , VVariable
                                    (VArray
                                       (VInt 0, 5, VTBool, ImArray.make 5 (VBool false)))
                                ) )
                            ; "n", (VTInt, VConst (VInt 9))
                            ; ( "ff"
                              , ( VTFunction ([], VTBool)
                                , VConst
                                    (VFunction
                                       ( "ff"
                                       , VTBool
                                       , []
                                       , KeyMap.of_seq
                                           (List.to_seq
                                              [ ( "ff"
                                                , (VTBool, VFunctionResult (VBool false))
                                                )
                                              ; ( "a"
                                                , ( VTArray (VInt 0, 10, VTBool)
                                                  , VVariable
                                                      (VArray
                                                         ( VInt 0
                                                         , 10
                                                         , VTBool
                                                         , ImArray.make 10 (VBool false)
                                                         )) ) )
                                              ])
                                       , [] )) ) )
                            ])
                     , [] )) ) )
          ; "nn", (VTInt, VConst (VInt 4))
          ]))
;;