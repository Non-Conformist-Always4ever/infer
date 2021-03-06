(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

module MF = MarkupFormatter

type linter = {
  condition : CTL.t;
  issue_desc : CIssue.issue_desc;
  def_file : string option;
}

(* If in linter developer mode and if current linter was passed, filter it out *)
let filter_parsed_linters parsed_linters =
  if List.length parsed_linters > 1 && Config.linters_developer_mode then
    match Config.linter with
    | None ->
        failwith ("ERROR: In linters developer mode you should debug only one linter at a time. \
                   This is important for debugging the rule. Pass the flag \
                   --linter <name> to specify the linter you want to debug.");
    | Some lint ->
        List.filter ~f:(
          fun (rule : linter) -> String.equal rule.issue_desc.name lint
        ) parsed_linters
  else parsed_linters

let linters_to_string linters =
  let linter_to_string linters =
    List.map ~f:(fun (rule : linter) -> rule.issue_desc.name) linters  in
  String.concat ~sep:"\n" (linter_to_string linters)

(* Map a formula id to a triple (visited, parameters, definition).
   Visited is used during the expansion phase to understand if the
   formula was already expanded and, if yes we have a cyclic definifion *)
type macros_map = (bool * ALVar.t list * CTL.t) ALVar.FormulaIdMap.t

let single_to_multi checker =
  fun ctx an ->
    let issue_desc_opt = checker ctx an in
    Option.to_list issue_desc_opt

(* List of checkers on decls *that return 0 or 1 issue* *)
let decl_single_checkers_list =
  [ComponentKit.component_with_unconventional_superclass_advice;
   ComponentKit.mutable_local_vars_advice;
   ComponentKit.component_factory_function_advice;
   ComponentKit.component_file_cyclomatic_complexity_info;]

(* List of checkers on decls *)
let decl_checkers_list =
  ComponentKit.component_with_multiple_factory_methods_advice::
  (ComponentKit.component_file_line_count_info::
   (List.map ~f:single_to_multi decl_single_checkers_list))

(* List of checkers on stmts *that return 0 or 1 issue* *)
let stmt_single_checkers_list =
  [ComponentKit.component_file_cyclomatic_complexity_info;
   ComponentKit.component_initializer_with_side_effects_advice;
   GraphQL.DeprecatedAPIUsage.checker;]

let stmt_checkers_list = List.map ~f:single_to_multi stmt_single_checkers_list

(* List of checkers that will be filled after parsing them from
   input the linter def files *)
let parsed_linters = ref []

let evaluate_place_holder ph an =
  match ph with
  | "%ivar_name%" -> MF.monospaced_to_string (CFrontend_checkers.ivar_name an)
  | "%decl_name%" -> MF.monospaced_to_string (Ctl_parser_types.ast_node_name an)
  | "%cxx_ref_captured_in_block%" ->
      MF.monospaced_to_string (CFrontend_checkers.cxx_ref_captured_in_block an)
  | "%decl_ref_or_selector_name%" ->
      MF.monospaced_to_string (CFrontend_checkers.decl_ref_or_selector_name an)
  | "%iphoneos_target_sdk_version%" ->
      MF.monospaced_to_string (CFrontend_checkers.iphoneos_target_sdk_version an)
  | "%available_ios_sdk%" -> MF.monospaced_to_string (CFrontend_checkers.available_ios_sdk an)
  | _ -> (Logging.out "ERROR: helper function %s is unknown. Stop.\n" ph;
          assert false)

(* given a message this function searches for a place-holder identifier,
   eg %id%. Then it evaluates id and replaces %id% in message
   with the result of its evaluation. The function keeps on checking if
   other place-holders exist and repeats the process until there are
    no place-holder left.
*)
let rec expand_message_string message an =
  (* reg exp should match alphanumeric id with possibly somee _ *)
  let re = Str.regexp "%[a-zA-Z0-9_]+%" in
  try
    let _ = Str.search_forward re message 0 in
    let ms = Str.matched_string message in
    let res = evaluate_place_holder ms an in
    Logging.out "\nMatched string '%s'\n" ms;
    let re_ms = Str.regexp_string ms in
    let message' = Str.replace_first re_ms res message in
    Logging.out "Replacing %s in message: \n %s \n" ms message;
    Logging.out "Resulting message: \n %s \n" message';
    expand_message_string message' an
  with Not_found -> message

let remove_new_lines message =
  String.substr_replace_all ~pattern:"\n" ~with_:" " message

let string_to_err_kind = function
  | "WARNING" -> Exceptions.Kwarning
  | "ERROR" -> Exceptions.Kerror
  | "INFO" -> Exceptions.Kinfo
  | "ADVICE" -> Exceptions.Kadvice
  | "LIKE" -> Exceptions.Klike
  | s -> (Logging.out "\n[ERROR] Severity %s does not exist. Stop.\n" s;
          assert false)

let string_to_issue_mode m =
  match m with
  | "ON" -> CIssue.On
  | "OFF" -> CIssue.Off
  | s ->
      (Logging.out "\n[ERROR] Mode %s does not exist. Please specify ON/OFF\n" s;
       assert false)

(** Convert a parsed checker in list of linters *)
let create_parsed_linters linters_def_file checkers : linter list =
  let open CIssue in
  let open CTL in
  Logging.out "\n Converting checkers in (condition, issue) pairs\n";
  let do_one_checker c =
    let dummy_issue = {
      name = c.name;
      description = "";
      suggestion = None;
      loc = Location.dummy;
      severity = Exceptions.Kwarning;
      mode = CIssue.On;
    } in
    let issue_desc, condition = List.fold ~f:(fun (issue', cond') d  ->
        match d with
        | CSet (av, phi) when ALVar.is_report_when_keyword av ->
            issue', phi
        | CDesc (av, msg) when ALVar.is_message_keyword  av ->
            {issue' with description = msg}, cond'
        | CDesc (av, sugg) when ALVar.is_suggestion_keyword  av ->
            {issue' with suggestion = Some sugg}, cond'
        | CDesc (av, sev) when ALVar.is_severity_keyword  av ->
            {issue' with severity = string_to_err_kind sev}, cond'
        | CDesc (av, m) when ALVar.is_mode_keyword  av ->
            {issue' with mode = string_to_issue_mode m }, cond'
        | _ -> issue', cond') ~init:(dummy_issue, CTL.False) c.definitions in
    if Config.debug_mode then (
      Logging.out "\nMaking condition and issue desc for checker '%s'\n"
        c.name;
      Logging.out "\nCondition =\n     %a\n" CTL.Debug.pp_formula condition;
      Logging.out "\nIssue_desc = %a\n" CIssue.pp_issue issue_desc);
    {condition; issue_desc; def_file = Some linters_def_file} in
  List.map ~f:do_one_checker checkers

let rec apply_substitution f sub =
  let sub_param p = try
      snd (List.find_exn sub ~f:(fun (a,_) -> ALVar.equal p a))
    with Not_found -> p in
  let sub_list_param ps =
    List.map ps ~f:sub_param in
  let open CTL in
  match f with
  | True
  | False -> f
  | Atomic (name, ps) ->
      Atomic (name, sub_list_param ps)
  | Not f1 ->
      Not (apply_substitution f1 sub)
  | And (f1, f2) ->
      And (apply_substitution f1 sub, apply_substitution f2 sub)
  | Or (f1, f2) ->
      Or (apply_substitution f1 sub, apply_substitution f2 sub)
  | Implies (f1, f2) ->
      Implies (apply_substitution f1 sub, apply_substitution f2 sub)
  | InNode (node_type_list, f1) ->
      InNode (sub_list_param node_type_list, apply_substitution f1 sub)
  | AU (trans, f1, f2) ->
      AU (trans, apply_substitution f1 sub, apply_substitution f2 sub)
  | EU (trans, f1, f2) ->
      EU (trans, apply_substitution f1 sub, apply_substitution f2 sub)
  | EF (trans, f1) ->
      EF (trans, apply_substitution f1 sub)
  | AF (trans, f1) ->
      AF (trans, apply_substitution f1 sub)
  | AG (trans, f1) ->
      AG (trans, apply_substitution f1 sub)
  | EX (trans, f1) ->
      EX (trans, apply_substitution f1 sub)
  | AX (trans, f1) ->
      AX (trans, apply_substitution f1 sub)
  | EH (cl, f1) ->
      EH (sub_list_param cl, apply_substitution f1 sub)
  | EG (trans, f1) ->
      EG (trans, apply_substitution f1 sub)
  | ET (ntl, sw, f1) ->
      ET (sub_list_param ntl, sw, apply_substitution f1 sub)
  | ETX (ntl, sw, f1) ->
      ETX (sub_list_param ntl, sw, apply_substitution f1 sub)

let expand_formula phi _map _error_msg =
  let fail_with_circular_macro_definition name error_msg =
    failwithf "Macro '%s' has a circular definition.\n Cycle:\n%s" name error_msg in
  let open CTL in
  let rec expand acc map error_msg =
    match acc with
    | True
    | False -> acc
    | Atomic (ALVar.Formula_id (name) as av, actual_param) -> (* it may be a macro *)
        (let error_msg' =
           error_msg ^ "  -Expanding formula identifier '" ^ name ^"'\n" in
         (try
            match ALVar.FormulaIdMap.find av map with
            | (true, _, _) ->
                fail_with_circular_macro_definition name error_msg'
            | (false, fparams, f1) -> (* in this case it should be a defined macro *)
                (match List.zip fparams actual_param with
                 | Some sub ->
                     let f1_sub = apply_substitution f1 sub in
                     let map' = ALVar.FormulaIdMap.add av (true, fparams, f1) map in
                     expand f1_sub map' error_msg'
                 | None -> failwith ("[ERROR]: Formula identifier '" ^ name ^
                                     "' is not called with the right number of parameters"))
          with Not_found -> acc)) (* in this case it should be a predicate *)
    | Not f1 -> Not (expand f1 map error_msg)
    | And (f1, f2) -> And (expand f1 map error_msg, expand f2 map error_msg)
    | Or (f1, f2) -> Or (expand f1 map error_msg, expand f2 map error_msg)
    | Implies (f1, f2) -> Implies (expand f1 map error_msg, expand f2 map error_msg)
    | InNode (node_type_list, f1) -> InNode (node_type_list, expand f1 map error_msg)
    | AU (trans, f1, f2) -> AU (trans, expand f1 map error_msg, expand f2 map error_msg)
    | EU (trans, f1, f2) -> EU (trans, expand f1 map error_msg, expand f2 map error_msg)
    | EF (trans, f1) -> EF (trans, expand f1 map error_msg)
    | AF (trans, f1) -> AF (trans, expand f1 map error_msg)
    | AG (trans, f1) -> AG (trans, expand f1 map error_msg)
    | EX (trans, f1) -> EX (trans, expand f1 map error_msg)
    | AX (trans, f1) -> AX (trans, expand f1 map error_msg)
    | EH (cl, f1) -> EH (cl, expand f1 map error_msg)
    | EG (trans, f1) -> EG (trans, expand f1 map error_msg)
    | ET (tl, sw, f1) -> ET (tl, sw, expand f1 map error_msg)
    | ETX (tl, sw, f1) -> ETX (tl, sw, expand f1 map error_msg) in
  expand phi _map _error_msg

let _build_macros_map macros init_map =
  let macros_map = List.fold ~f:(fun map' data -> match data with
      | CTL.CLet (key, params, formula) ->
          if ALVar.FormulaIdMap.mem key map' then
            failwith ("[ERROR] Macro '" ^ (ALVar.formula_id_to_string key) ^
                      "' has more than one definition.")
          else ALVar.FormulaIdMap.add key (false, params, formula) map'
      | _ -> map') ~init:init_map macros in
  macros_map

let build_macros_map macros =
  let init_map : macros_map = ALVar.FormulaIdMap.empty in
  _build_macros_map macros init_map

(* expands use of let defined formula id in checkers with their definition *)
let expand_checkers macro_map checkers =
  let open CTL in
  let expand_one_checker c =
    Logging.out " +Start expanding %s\n" c.name;
    let map = _build_macros_map c.definitions macro_map in
    let exp_defs = List.fold ~f:(fun defs clause ->
        match clause with
        | CSet (report_when_const, phi) ->
            Logging.out "  -Expanding report_when\n";
            CSet (report_when_const, expand_formula phi map "") :: defs
        | cl -> cl :: defs) ~init:[] c.definitions in
    { c with definitions = exp_defs} in
  List.map ~f:expand_one_checker checkers

let get_err_log translation_unit_context method_decl_opt =
  let procname = match method_decl_opt with
    | Some method_decl -> CProcname.from_decl translation_unit_context method_decl
    | None -> Typ.Procname.Linters_dummy_method in
  LintIssues.get_err_log procname

(* Add a frontend warning with a description desc at location loc to the errlog of a proc desc *)
let log_frontend_issue translation_unit_context method_decl_opt key issue_desc linters_def_file =
  let name = issue_desc.CIssue.name in
  let loc = issue_desc.CIssue.loc in
  let errlog = get_err_log translation_unit_context method_decl_opt in
  let err_desc = Errdesc.explain_frontend_warning issue_desc.CIssue.description
      issue_desc.CIssue.suggestion loc in
  let exn = Exceptions.Frontend_warning (name, err_desc, __POS__) in
  let trace = [ Errlog.make_trace_element 0 issue_desc.CIssue.loc "" [] ] in
  let err_kind = issue_desc.CIssue.severity in
  let method_name = CAst_utils.full_name_of_decl_opt method_decl_opt
                    |> QualifiedCppName.to_qual_string in
  let key = Hashtbl.hash (key ^ method_name) in
  Reporting.log_issue_from_errlog err_kind errlog exn ~loc ~ltr:trace
    ~node_id:(0, key) ?linters_def_file

let get_current_method context (an : Ctl_parser_types.ast_node) =
  match an with
  | Decl (FunctionDecl _ as d)
  | Decl (CXXMethodDecl _ as d)
  | Decl (CXXConstructorDecl _ as d)
  | Decl (CXXConversionDecl _ as d)
  | Decl (CXXDestructorDecl _ as d)
  | Decl (ObjCMethodDecl _ as d)
  | Decl (BlockDecl _ as d) -> Some d
  | _ -> context.CLintersContext.current_method

let fill_issue_desc_info_and_log context an key issue_desc linters_def_file loc =
  let desc = remove_new_lines
      (expand_message_string issue_desc.CIssue.description an) in
  let issue_desc' =
    {issue_desc with CIssue.description = desc; CIssue.loc = loc } in
  log_frontend_issue context.CLintersContext.translation_unit_context
    (get_current_method context an) key issue_desc' linters_def_file

(* Calls the set of hard coded checkers (if any) *)
let invoke_set_of_hard_coded_checkers_an context (an : Ctl_parser_types.ast_node) =
  let checkers, key  = match an with
    | Decl dec -> decl_checkers_list, CAst_utils.generate_key_decl dec
    | Stmt st -> stmt_checkers_list, CAst_utils.generate_key_stmt st in
  List.iter ~f:(fun checker ->
      let issue_desc_list = checker context an in
      List.iter ~f:(fun issue_desc ->
          if CIssue.should_run_check issue_desc.CIssue.mode then
            fill_issue_desc_info_and_log context an key issue_desc None issue_desc.CIssue.loc
        ) issue_desc_list
    ) checkers

(* Calls the set of checkers parsed from files (if any) *)
let invoke_set_of_parsed_checkers_an parsed_linters context (an : Ctl_parser_types.ast_node) =
  let key = match an with
    | Decl dec -> CAst_utils.generate_key_decl dec
    | Stmt st -> CAst_utils.generate_key_stmt st in
  List.iter ~f:(fun (linter : linter) ->
      if CIssue.should_run_check linter.issue_desc.CIssue.mode &&
         CTL.eval_formula linter.condition an context then
        let loc = CFrontend_checkers.location_from_an context an in
        fill_issue_desc_info_and_log context an key linter.issue_desc linter.def_file loc
    ) parsed_linters

(* We decouple the hardcoded checkers from the parsed ones *)
let invoke_set_of_checkers_on_node context an =
  (match an with
   | Ctl_parser_types.Decl (Clang_ast_t.TranslationUnitDecl _) ->
       (* Don't run parsed linters on TranslationUnitDecl node.
          Because depending on the formula it may give an error at line -1 *)
       ()
   | _ -> invoke_set_of_parsed_checkers_an !parsed_linters context an);
  if Config.default_linters then invoke_set_of_hard_coded_checkers_an context an
