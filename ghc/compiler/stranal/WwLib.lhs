%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%
\section[WwLib]{A library for the ``worker/wrapper'' back-end to the strictness analyser}

\begin{code}
module WwLib ( mkWwBodies ) where

#include "HsVersions.h"

import CoreSyn
import CoreUtils	( exprType )
import Id		( Id, idType, mkSysLocal, idNewDemandInfo, setIdNewDemandInfo,
			  isOneShotLambda, setOneShotLambda, setIdUnfolding,
                          setIdInfo
			)
import IdInfo		( vanillaIdInfo )
import DataCon		( splitProductType_maybe, splitProductType )
import NewDemand	( Demand(..), Keepity(..), DmdResult(..) ) 
import DmdAnal		( both )
import PrelInfo		( realWorldPrimId, aBSENT_ERROR_ID, eRROR_CSTRING_ID )
import TysPrim		( realWorldStatePrimTy )
import TysWiredIn	( tupleCon )
import Type		( Type, isUnLiftedType, mkFunTys,
			  splitForAllTys, splitFunTys, splitNewType_maybe, isAlgType
			)
import Literal		( Literal(MachStr) )
import BasicTypes	( Boxity(..) )
import Var              ( Var, isId )
import UniqSupply	( returnUs, thenUs, getUniqueUs, getUniquesUs, UniqSM )
import Util		( zipWithEqual )
import Outputable
import List		( zipWith4 )
\end{code}


%************************************************************************
%*									*
\subsection[mkWrapperAndWorker]{@mkWrapperAndWorker@}
%*									*
%************************************************************************

Here's an example.  The original function is:

\begin{verbatim}
g :: forall a . Int -> [a] -> a

g = /\ a -> \ x ys ->
	case x of
	  0 -> head ys
	  _ -> head (tail ys)
\end{verbatim}

From this, we want to produce:
\begin{verbatim}
-- wrapper (an unfolding)
g :: forall a . Int -> [a] -> a

g = /\ a -> \ x ys ->
	case x of
	  I# x# -> $wg a x# ys
	    -- call the worker; don't forget the type args!

-- worker
$wg :: forall a . Int# -> [a] -> a

$wg = /\ a -> \ x# ys ->
	let
	    x = I# x#
	in
	    case x of		    -- note: body of g moved intact
	      0 -> head ys
	      _ -> head (tail ys)
\end{verbatim}

Something we have to be careful about:  Here's an example:

\begin{verbatim}
-- "f" strictness: U(P)U(P)
f (I# a) (I# b) = a +# b

g = f	-- "g" strictness same as "f"
\end{verbatim}

\tr{f} will get a worker all nice and friendly-like; that's good.
{\em But we don't want a worker for \tr{g}}, even though it has the
same strictness as \tr{f}.  Doing so could break laziness, at best.

Consequently, we insist that the number of strictness-info items is
exactly the same as the number of lambda-bound arguments.  (This is
probably slightly paranoid, but OK in practice.)  If it isn't the
same, we ``revise'' the strictness info, so that we won't propagate
the unusable strictness-info into the interfaces.


%************************************************************************
%*									*
\subsection{The worker wrapper core}
%*									*
%************************************************************************

@mkWwBodies@ is called when doing the worker/wrapper split inside a module.

\begin{code}
mkWwBodies :: Type				-- Type of original function
	   -> [Demand]				-- Strictness of original function
	   -> DmdResult				-- Info about function result
	   -> [Bool]				-- One-shot-ness of the function
	   -> UniqSM ([Demand],			-- Demands for worker (value) args
		      Id -> CoreExpr,		-- Wrapper body, lacking only the worker Id
		      CoreExpr -> CoreExpr)	-- Worker body, lacking the original function rhs

-- wrap_fn_args E	= \x y -> E
-- work_fn_args E	= E x y

-- wrap_fn_str E 	= case x of { (a,b) -> 
--			  case a of { (a1,a2) ->
--			  E a1 a2 b y }}
-- work_fn_str E	= \a2 a2 b y ->
--			  let a = (a1,a2) in
--			  let x = (a,b) in
--			  E

mkWwBodies fun_ty demands res_info one_shots
  = mkWWargs fun_ty demands one_shots'	`thenUs` \ (wrap_args,   wrap_fn_args, work_fn_args, res_ty) ->
    mkWWcpr res_ty res_info      	`thenUs` \ (wrap_fn_cpr, work_fn_cpr,  cpr_res_ty) ->
    mkWWstr cpr_res_ty wrap_args	`thenUs` \ (work_dmds,   wrap_fn_str,  work_fn_str) ->

    returnUs (work_dmds,
	      Note InlineMe . wrap_fn_args . wrap_fn_cpr . wrap_fn_str . Var,
	      work_fn_str . work_fn_cpr . work_fn_args)
	-- We use an INLINE unconditionally, even if the wrapper turns out to be
	-- something trivial like
	--	fw = ...
	--	f = __inline__ (coerce T fw)
	-- The point is to propagate the coerce to f's call sites, so even though
	-- f's RHS is now trivial (size 1) we still want the __inline__ to prevent
	-- fw from being inlined into f's RHS
  where
    one_shots' = one_shots ++ repeat False
\end{code}


%************************************************************************
%*									*
\subsection{Coercion stuff}
%*									*
%************************************************************************


We really want to "look through" coerces.
Reason: I've seen this situation:

	let f = coerce T (\s -> E)
	in \x -> case x of
	   	    p -> coerce T' f
		    q -> \s -> E2
	   	    r -> coerce T' f

If only we w/w'd f, we'd get
	let f = coerce T (\s -> fw s)
	    fw = \s -> E
	in ...

Now we'll inline f to get

	let fw = \s -> E
	in \x -> case x of
	   	    p -> fw
		    q -> \s -> E2
	   	    r -> fw

Now we'll see that fw has arity 1, and will arity expand
the \x to get what we want.

\begin{code}
-- mkWWargs is driven off the function type and arity.
-- It chomps bites off foralls, arrows, newtypes
-- and keeps repeating that until it's satisfied the supplied arity

mkWWargs :: Type
	 -> [Demand]
	 -> [Bool]			-- True for a one-shot arg; ** may be infinite **
	 -> UniqSM  ([Var],		-- Wrapper args
		     CoreExpr -> CoreExpr,	-- Wrapper fn
		     CoreExpr -> CoreExpr,	-- Worker fn
		     Type)			-- Type of wrapper body

mkWWargs fun_ty demands one_shots
  | Just rep_ty <- splitNewType_maybe fun_ty
   	-- The newtype case is for when the function has
	-- a recursive newtype after the arrow (rare)
	-- We check for arity >= 0 to avoid looping in the case
	-- of a function whose type is, in effect, infinite
	-- [Arity is driven by looking at the term, not just the type.]
	--
	-- It's also important when we have a function returning (say) a pair
	-- wrapped in a recursive newtype, at least if CPR analysis can look 
	-- through such newtypes, which it probably can since they are 
	-- simply coerces.
  = mkWWargs rep_ty demands one_shots	`thenUs` \ (wrap_args, wrap_fn_args, work_fn_args, res_ty) ->
    returnUs (wrap_args,
	      Note (Coerce fun_ty rep_ty) . wrap_fn_args,
	      work_fn_args . Note (Coerce rep_ty fun_ty),
	      res_ty)

  | not (null demands)
  = getUniquesUs 		`thenUs` \ wrap_uniqs ->
    let
      (tyvars, tau)      	= splitForAllTys fun_ty
      (arg_tys, body_ty) 	= splitFunTys tau

      n_demands	= length demands
      n_arg_tys	= length arg_tys
      n_args    = n_demands `min` n_arg_tys

      new_fun_ty    = mkFunTys (drop n_demands arg_tys) body_ty
      new_demands   = drop n_arg_tys demands
      new_one_shots = drop n_args one_shots

      val_args	= zipWith4 mk_wrap_arg wrap_uniqs arg_tys demands one_shots
      wrap_args = tyvars ++ val_args
    in
{-     ASSERT( not (null tyvars) || not (null arg_tys) ) -}
    if (null tyvars) && (null arg_tys) then
	pprTrace "mkWWargs" (ppr fun_ty $$ ppr demands) 
		returnUs ([], id, id, fun_ty)
	else

    mkWWargs new_fun_ty
	     new_demands
	     new_one_shots	`thenUs` \ (more_wrap_args, wrap_fn_args, work_fn_args, res_ty) ->

    returnUs (wrap_args ++ more_wrap_args,
	      mkLams wrap_args . wrap_fn_args,
	      work_fn_args . applyToVars wrap_args,
	      res_ty)

  | otherwise
  = returnUs ([], id, id, fun_ty)


applyToVars :: [Var] -> CoreExpr -> CoreExpr
applyToVars vars fn = mkVarApps fn vars

mk_wrap_arg uniq ty dmd one_shot 
  = set_one_shot one_shot (setIdNewDemandInfo (mkSysLocal SLIT("w") uniq ty) dmd)
  where
    set_one_shot True  id = setOneShotLambda id
    set_one_shot False id = id
\end{code}


%************************************************************************
%*									*
\subsection{Strictness stuff}
%*									*
%************************************************************************

\begin{code}
mkWWstr :: Type					-- Result type
	-> [Var]				-- Wrapper args; have their demand info on them
						-- *Includes type variables*
        -> UniqSM ([Demand],			-- Demand on worker (value) args
		   CoreExpr -> CoreExpr,	-- Wrapper body, lacking the worker call
						-- and without its lambdas 
						-- This fn adds the unboxing, and makes the
						-- call passing the unboxed things
				
		   CoreExpr -> CoreExpr)	-- Worker body, lacking the original body of the function,
						-- but *with* lambdas

mkWWstr res_ty wrap_args
  = mk_ww_str_s wrap_args		`thenUs` \ (work_args, take_apart, put_together) ->
    let
	work_dmds = [idNewDemandInfo v | v <- work_args, isId v]
	apply_to args fn = mkVarApps fn args
    in
    if not (null work_dmds && isUnLiftedType res_ty) then
	returnUs ( work_dmds, 
		   take_apart . applyToVars work_args,
		   mkLams work_args . put_together)
    else
 	-- Horrid special case.  If the worker would have no arguments, and the
	-- function returns a primitive type value, that would make the worker into
	-- an unboxed value.  We box it by passing a dummy void argument, thus:
	--
	--	f = /\abc. \xyz. fw abc void
	-- 	fw = /\abc. \v. body
	--
	-- We use the state-token type which generates no code
    getUniqueUs 		`thenUs` \ void_arg_uniq ->
    let
	void_arg = mk_ww_local void_arg_uniq realWorldStatePrimTy
    in
    returnUs ([Lazy],		
	      take_apart . applyToVars [realWorldPrimId] . apply_to work_args,
	      mkLams work_args . Lam void_arg . put_together)

----------------------
nop_fn body = body

----------------------
mk_ww_str_s []
  = returnUs ([], nop_fn, nop_fn)

mk_ww_str_s (arg : args)
  = mk_ww_str arg		`thenUs` \ (args1, wrap_fn1, work_fn1) ->
    mk_ww_str_s args		`thenUs` \ (args2, wrap_fn2, work_fn2) ->
    returnUs (args1 ++ args2, wrap_fn1 . wrap_fn2, work_fn1 . work_fn2)


----------------------
mk_ww_str arg
  | isTyVar arg
  = returnUs ([arg],  nop_fn, nop_fn)

  | otherwise
  = case idNewDemandInfo arg of

	-- Absent case.  We don't deal with absence for unlifted types,
	-- though, because it's not so easy to manufacture a placeholder
	-- We'll see if this turns out to be a problem
      Abs | not (isUnLiftedType (idType arg)) ->
	returnUs ([], nop_fn, mk_absent_let arg) 

	-- Seq and keep
      Seq _ []
	-> let
		arg_w_unf = arg `setIdUnfolding` mkOtherCon []
		-- Tell the worker arg that it's sure to be evaluated
		-- so that internal seqs can be dropped
	   in
	   returnUs ([arg_w_unf], mk_seq_case arg, nop_fn)
	  	-- Pass the arg, anyway, even if it is in theory discarded
		-- Consider
		--	f x y = x `seq` y
		-- x gets a (Seq Drop []) demand, but if we fail to pass it to the worker
		-- we ABSOLUTELY MUST record that x is evaluated in the wrapper.
		-- Something like:
		--	f x y = x `seq` fw y
		--	fw y = let x{Evald} = error "oops" in (x `seq` y)
		-- If we don't pin on the "Evald" flag, the seq doesn't disappear, and
		-- we end up evaluating the absent thunk.
		-- But the Evald flag is pretty wierd, and I worry that it might disappear
		-- during simplification, so for now I've just nuked this whole case
			
	-- Unpack case
      Seq keep cs 
	| Just (arg_tycon, tycon_arg_tys, data_con, inst_con_arg_tys) 
		<- splitProductType_maybe (idType arg)
	-> getUniquesUs 		`thenUs` \ uniqs ->
	   let
	     unpk_args	    = zipWith mk_ww_local uniqs inst_con_arg_tys
	     unpk_args_w_ds = zipWithEqual "mk_ww_str" set_worker_arg_info unpk_args cs'
	     unbox_fn       = mk_unpk_case arg unpk_args data_con arg_tycon
	     rebox_fn	    = Let (NonRec arg con_app) 
	     con_app	    = mkConApp data_con (map Type tycon_arg_tys ++ map Var unpk_args)

	     cs' = case keep of
			Keep -> map (DmdAnal.both Lazy) cs	-- Careful! Now we don't pass
								-- the box, we must pass all the
								-- components.   In effect
								-- 	S(LA) -->  U(LL)
			Drop -> cs
	   in
	   mk_ww_str_s unpk_args_w_ds		`thenUs` \ (worker_args, wrap_fn, work_fn) ->

--	   case keep of
--	     Keep -> returnUs (arg : worker_args, unbox_fn . wrap_fn, work_fn)
--	  		   -- Pass the arg, no need to rebox
--	     Drop -> returnUs (worker_args,       unbox_fn . wrap_fn, work_fn . rebox_fn)
--	  		   -- Don't pass the arg, rebox instead
-- I used to be clever here, but consider
--	f n []     = n
--	f n (x:xs) = f (n+x) xs
-- Here n gets (Seq Keep [L]), but it's BAD BAD BAD to pass both n and n#
-- Needs more thought, but the simple thing to do is to accept the reboxing
-- stuff if there are any non-absent arguments (and that case is dealt with above):

	   returnUs (worker_args, unbox_fn . wrap_fn, work_fn . rebox_fn)
	  		   -- Don't pass the arg, rebox instead

	| otherwise -> 
	   WARN( True, ppr arg )
	   returnUs ([arg], nop_fn, nop_fn)

	-- Other cases
      other_demand -> returnUs ([arg], nop_fn, nop_fn)

  where
	-- If the wrapper argument is a one-shot lambda, then
	-- so should (all) the corresponding worker arguments be
	-- This bites when we do w/w on a case join point
    set_worker_arg_info worker_arg demand = set_one_shot (setIdNewDemandInfo worker_arg demand)

    set_one_shot | isOneShotLambda arg = setOneShotLambda
		 | otherwise	       = \x -> x
\end{code}


%************************************************************************
%*									*
\subsection{CPR stuff}
%*									*
%************************************************************************


@mkWWcpr@ takes the worker/wrapper pair produced from the strictness
info and adds in the CPR transformation.  The worker returns an
unboxed tuple containing non-CPR components.  The wrapper takes this
tuple and re-produces the correct structured output.

The non-CPR results appear ordered in the unboxed tuple as if by a
left-to-right traversal of the result structure.


\begin{code}
mkWWcpr :: Type                              -- function body type
        -> DmdResult                         -- CPR analysis results
        -> UniqSM (CoreExpr -> CoreExpr,             -- New wrapper 
                   CoreExpr -> CoreExpr,	     -- New worker
		   Type)			-- Type of worker's body 

mkWWcpr body_ty RetCPR
    | not (isAlgType body_ty)
    = WARN( True, text "mkWWcpr: non-algebraic body type" <+> ppr body_ty )
      returnUs (id, id, body_ty)

    | n_con_args == 1 && isUnLiftedType con_arg_ty1
	-- Special case when there is a single result of unlifted type
    = getUniquesUs 			`thenUs` \ (work_uniq : arg_uniq : _) ->
      let
	work_wild = mk_ww_local work_uniq body_ty
	arg	  = mk_ww_local arg_uniq  con_arg_ty1
      in
      returnUs (\ wkr_call -> Case wkr_call arg [(DEFAULT, [], mkConApp data_con (map Type tycon_arg_tys ++ [Var arg]))],
		\ body     -> workerCase body work_wild [(DataAlt data_con, [arg], Var arg)],
		con_arg_ty1)

    | otherwise		-- The general case
    = getUniquesUs 	  	`thenUs` \ uniqs ->
      let
        (wrap_wild : work_wild : args) = zipWith mk_ww_local uniqs (ubx_tup_ty : body_ty : con_arg_tys)
	arg_vars		       = map Var args
	ubx_tup_con		       = tupleCon Unboxed n_con_args
	ubx_tup_ty		       = exprType ubx_tup_app
	ubx_tup_app		       = mkConApp ubx_tup_con (map Type con_arg_tys   ++ arg_vars)
        con_app			       = mkConApp data_con    (map Type tycon_arg_tys ++ arg_vars)
      in
      returnUs (\ wkr_call -> Case wkr_call wrap_wild [(DataAlt ubx_tup_con, args, con_app)],
		\ body     -> workerCase body work_wild [(DataAlt data_con,    args, ubx_tup_app)],
		ubx_tup_ty)
    where
      (_, tycon_arg_tys, data_con, con_arg_tys) = splitProductType "mkWWcpr" body_ty
      n_con_args  = length con_arg_tys
      con_arg_ty1 = head con_arg_tys

mkWWcpr body_ty other		-- No CPR info
    = returnUs (id, id, body_ty)

-- If the original function looked like
--	f = \ x -> _scc_ "foo" E
--
-- then we want the CPR'd worker to look like
--	\ x -> _scc_ "foo" (case E of I# x -> x)
-- and definitely not
--	\ x -> case (_scc_ "foo" E) of I# x -> x)
--
-- This transform doesn't move work or allocation
-- from one cost centre to another

workerCase (Note (SCC cc) e) arg alts = Note (SCC cc) (Case e arg alts)
workerCase e		     arg alts = Case e arg alts
\end{code}


%************************************************************************
%*									*
\subsection{Utilities}
%*									*
%************************************************************************


\begin{code}
mk_absent_let arg body
  | not (isUnLiftedType arg_ty)
  = Let (NonRec arg abs_rhs) body
  | otherwise
  = panic "WwLib: haven't done mk_absent_let for primitives yet"
  where
    arg_ty = idType arg
--    abs_rhs = mkTyApps (Var aBSENT_ERROR_ID) [arg_ty]
    abs_rhs = mkApps (Var eRROR_CSTRING_ID) [Type arg_ty, Lit (MachStr (_PK_ msg))] 
    msg     = "Oops!  Entered absent arg " ++ showSDocDebug (ppr arg <+> ppr (idType arg))

mk_unpk_case arg unpk_args boxing_con boxing_tycon body
	-- A data type
  = Case (Var arg) 
	 (sanitiseCaseBndr arg)
	 [(DataAlt boxing_con, unpk_args, body)]

mk_seq_case arg body = Case (Var arg) (sanitiseCaseBndr arg) [(DEFAULT, [], body)]

sanitiseCaseBndr :: Id -> Id
-- The argument we are scrutinising has the right type to be
-- a case binder, so it's convenient to re-use it for that purpose.
-- But we *must* throw away all its IdInfo.  In particular, the argument
-- will have demand info on it, and that demand info may be incorrect for
-- the case binder.  e.g.  	case ww_arg of ww_arg { I# x -> ... }
-- Quite likely ww_arg isn't used in '...'.  The case may get discarded
-- if the case binder says "I'm demanded".  This happened in a situation 
-- like		(x+y) `seq` ....
sanitiseCaseBndr id = id `setIdInfo` vanillaIdInfo

mk_ww_local uniq ty = mkSysLocal SLIT("ww") uniq ty
\end{code}
