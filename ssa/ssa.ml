open Core_kernel.Std
open Bap.Std
open Format

let succ_of_jmp  jmp = match Jmp.kind jmp with
  | Goto (Direct tid) -> Some tid
  | Call t -> Option.(Call.return t >>= function
    | Direct tid -> Some tid
    | _ -> None)
  | Int (_,tid) -> Some tid
  | _ -> None

(** builds a map from a tid to all blocks that have jumps that lead
    this tid. *)
let build_rdep sub : tid list Tid.Map.t =
  Term.to_sequence blk_t sub |>
  Seq.fold ~init:Tid.Map.empty ~f:(fun ins blk ->
      Term.to_sequence jmp_t blk |>
      Seq.fold ~init:ins ~f:(fun ins jmp ->
          Option.value_map (succ_of_jmp jmp) ~default:ins ~f:(fun tid ->
              Map.add_multi ins ~key:tid ~data:(Term.tid blk))))

type dom = {
  frontier : tid -> tid list;
  children : tid -> tid list;
}

let create_dom rdep sub entry =
  let module Dom = Graph.Dominator.Make(struct
      type t = (sub term * tid list Tid.Map.t)
      module V = Tid
      let pred (_,rdep) tid = match Map.find rdep tid with
        | None -> []
        | Some xs -> xs
      let succ (sub,_) tid = match Term.find blk_t sub tid with
        | None -> []
        | Some blk ->
          Term.to_sequence jmp_t ~rev:true blk |>
          Seq.filter_map ~f:succ_of_jmp |>
          Seq.to_list_rev
      let fold_vertex f (sub,_) init =
        Term.to_sequence blk_t sub |>
        Seq.fold ~init ~f:(fun a v -> f (Term.tid v) a)
      let iter_vertex f (sub,_) =
        Term.to_sequence blk_t sub |>
        Seq.map ~f:Term.tid |> Seq.iter ~f
      let nb_vertex (sub,_) = Term.length blk_t sub
    end) in
  let cfg = sub, rdep in
  let idom = Dom.compute_idom cfg (Term.tid entry) in
  let dom_tree = Dom.idom_to_dom_tree cfg idom in
  {
    frontier = Dom.compute_dom_frontier cfg dom_tree idom;
    children = dom_tree
  }


(** [iterated_frontier frontier bs] given a [frontier] function, that
    for a each block [b] returns its dominance frontier, compute an
    iterated dominance frontier of a set of block [bs]. Iterated
    dominance frontier is defined inductively as
    [IDF_1(S) = DF(S); IDF_n(S) = DF(S U IDF_{n-1}(S))],
    where [DF(S)] computes a union of dominance frontiers of each
    block in [S].  The function returns a result of [IDF_k], where
    [k] is a fixpoint, i.e., such value that [IDF_k = IDF_{k-1}].  See
    section 8.11 of Advanced Compiler Design and Implementation
    [ISBN-10: 1558603204].*)
let iterated_frontier frontier blks =
  let df = Set.fold ~init:Tid.Set.empty ~f:(fun dfs b ->
      List.fold (frontier b) ~init:dfs ~f:Set.add) in
  let blks = List.fold blks ~init:Tid.Set.empty ~f:Set.add in
  let rec fixpoint idf =
    let idf' = df (Set.union idf blks) in
    if Set.equal idf idf' then idf' else fixpoint idf' in
  fixpoint Tid.Set.empty

(* todo, collect only globals *)
let collect_vars sub =
  Term.to_sequence blk_t sub |>
  Seq.fold ~init:Var.Set.empty ~f:(fun vars blk ->
      Term.to_sequence def_t blk |>
      Seq.fold ~init:vars ~f:(fun vars def ->
          Set.add vars (Def.lhs def)))

let blocks_that_define_var var sub =
  Term.to_sequence blk_t sub |>
  Seq.filter ~f:(fun blk ->
      Term.to_sequence ~rev:true def_t blk |>
      Seq.exists ~f:(fun def -> Var.(Def.lhs def = var))) |>
  Seq.map ~f:Term.tid |>
  Seq.to_list_rev

let substitute vars = (object
  inherit Bil.mapper as super
  method! map_sym z =
    match Hashtbl.find vars z with
    | None | Some [] -> z
    | Some (d :: _) -> d
end)#map_exp

let renumber v = Var.(create ~tmp:true (name v) (typ v))

let rename children phis vars sub entry =
  let vars : var list Var.Table.t = Var.Table.create () in
  let top v = match Hashtbl.find vars v with
    | None | Some [] -> v
    | Some (v :: _) -> v in
  let pop v = Hashtbl.change vars v (function
      | Some (x::xs) -> Some xs
      | xs -> xs) in
  let rename_defs blk =
    Term.map def_t blk ~f:(fun def ->
        let lhs = renumber (Def.lhs def) in
        Hashtbl.add_multi vars ~key:(Def.lhs def) ~data:lhs;
        Def.rhs def |> substitute vars |>
        Def.with_rhs (Def.with_lhs def lhs)) in
  let rename_jmps blk =
    Term.map jmp_t blk
      ~f:(Jmp.map_exp ~f:(substitute vars)) in
  let rename_phis blk =
    Term.map phi_t blk ~f:(fun phi ->
        let lhs = renumber (Phi.lhs phi) in
        Hashtbl.add_multi vars ~key:(Phi.lhs phi) ~data:lhs;
        Phi.with_lhs phi lhs) in
  let update_phis src dst =
    match Map.find phis (Term.tid dst) with
    | None -> dst
    | Some vs ->
      let tid = Term.tid src in
      List.fold vs ~init:dst ~f:(fun dst v ->
          Term.to_sequence phi_t dst |>
          Seq.find ~f:(fun phi -> Var.(Phi.lhs phi = v)) |> function
          | None ->
            Phi.create v tid (Bil.var (top v)) |>
            Term.append phi_t dst
          | Some phi ->
            Phi.map_exp phi ~f:(substitute vars) |>
            Term.update phi_t dst) in
  let rec rename sub tid =
    let blk' = match Term.find blk_t sub tid with
      | None -> assert false
      | Some blk' -> blk' in
    let blk = blk' |> rename_phis |> rename_defs |> rename_jmps in
    let sub = Term.update blk_t sub blk in
    Term.to_sequence jmp_t blk |>
    Seq.fold ~init:sub ~f:(fun sub jmp -> match succ_of_jmp jmp with
        | None -> sub
        | Some tid -> match Term.find blk_t sub tid with
          | None -> sub
          | Some dst ->
            Term.update blk_t sub (update_phis blk dst)) |>
    fun sub ->
    List.fold (children tid) ~init:sub ~f:rename |>
    fun sub ->
    Term.to_sequence phi_t blk' |>
    Seq.iter ~f:(fun phi -> pop (Phi.lhs phi));
    Term.to_sequence def_t blk' |>
    Seq.iter ~f:(fun def -> pop (Def.lhs def));
    sub in
  rename sub entry

(** [find_phi_placeholders frontier sub entry vars] given a [frontier]
    function that for a given block returns its dominance frontier, a
    subroutine [sub] with entry block [entry] and a set of variable
    [vars] compute for each variable [x] in [vars] a set of blocks
    where a phi-node for [x] should be placed.  The algorithm computes
    an iterated dominance frontier for each variable as per section
    8.11 of Advanced Compiler Design and Implementation [ ISBN-10:
    1558603204].*)
let find_phi_placeholders frontier sub entry vars =
  Set.fold vars ~init:Tid.Map.empty ~f:(fun phis x ->
      let bs = blocks_that_define_var x sub in
      iterated_frontier frontier (entry :: bs) |>
      Set.fold ~init:phis ~f:(fun phis blk ->
          Map.add_multi phis ~data:x ~key:blk))

let ssa_sub sub = match Term.first blk_t sub with
  | None -> sub
  | Some entry ->
    let rdep = build_rdep sub in
    let dom = create_dom rdep sub entry in
    let vars = collect_vars sub in
    let phis =
      find_phi_placeholders dom.frontier sub (Term.tid entry) vars in
    rename dom.children phis vars sub (Term.tid entry)

let main' proj =
  Term.map sub_t (Project.program proj) ~f:ssa_sub |>
  printf "Program in SSA: @.%a@." Program.pp

let main proj =
  Project.with_program proj @@
  Term.map sub_t (Project.program proj) ~f:ssa_sub

let () = Project.register_pass "SSA" main
let () = Project.register_pass' "SSA'" main'
