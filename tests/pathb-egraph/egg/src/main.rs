// Equality saturation of the programs of gen.rb (the same random straight-line integer functions the e-graph pass reads).
// Rewrites and limits follow scripts/pathb-egraph.rb: commutativity of + and *, identities (x+0, x*1, x-0), x*0 and x-x,
// constant folding (an analysis, as the pass folds constants), 8 iterations, and 2000 nodes added beyond the input.
use egg::*;
use std::time::Instant;

define_language! {
    enum Arith {
        Num(i64),
        Sym(Symbol),
        "+" = Add([Id; 2]),
        "*" = Mul([Id; 2]),
        "-" = Sub([Id; 2]),
    }
}

#[derive(Default)]
struct ConstFold;
impl Analysis<Arith> for ConstFold {
    type Data = Option<i64>;
    fn merge(&mut self, to: &mut Option<i64>, from: Option<i64>) -> DidMerge {
        merge_option(to, from, |a, b| {
            assert_eq!(*a, b);
            DidMerge(false, false)
        })
    }
    fn make(egraph: &mut EGraph<Arith, Self>, enode: &Arith, _id: Id) -> Option<i64> {
        let x = |i: &Id| egraph[*i].data;
        match enode {
            Arith::Num(n) => Some(*n),
            // 32-bit wrapping, as the pass's wadd, wmul and wsub (an int is 32 bits in the IR)
            Arith::Add([a, b]) => Some((x(a)? as i32).wrapping_add(x(b)? as i32) as i64),
            Arith::Mul([a, b]) => Some((x(a)? as i32).wrapping_mul(x(b)? as i32) as i64),
            Arith::Sub([a, b]) => Some((x(a)? as i32).wrapping_sub(x(b)? as i32) as i64),
            Arith::Sym(_) => None,
        }
    }
    fn modify(egraph: &mut EGraph<Arith, Self>, id: Id) {
        if let Some(c) = egraph[id].data {
            let added = egraph.add(Arith::Num(c));
            egraph.union(id, added);
        }
    }
}

// A pattern variable that is bound to a constant class (the pass reassociates and rewrites constants only).
fn is_const(v: &str) -> impl Fn(&mut EGraph<Arith, ConstFold>, Id, &Subst) -> bool {
    let v: Var = v.parse().unwrap();
    move |egraph, _, subst| egraph[subst[v]].data.is_some()
}

fn both_const(a: &str, b: &str) -> impl Fn(&mut EGraph<Arith, ConstFold>, Id, &Subst) -> bool {
    let (a, b): (Var, Var) = (a.parse().unwrap(), b.parse().unwrap());
    move |egraph, _, subst| egraph[subst[a]].data.is_some() && egraph[subst[b]].data.is_some()
}

fn rules() -> Vec<Rewrite<Arith, ConstFold>> {
    vec![
        rewrite!("comm-add"; "(+ ?a ?b)" => "(+ ?b ?a)"),
        rewrite!("comm-mul"; "(* ?a ?b)" => "(* ?b ?a)"),
        rewrite!("add-0"; "(+ ?a 0)" => "?a"),
        rewrite!("sub-0"; "(- ?a 0)" => "?a"),
        rewrite!("mul-1"; "(* ?a 1)" => "?a"),
        rewrite!("mul-0"; "(* ?a 0)" => "0"),
        rewrite!("sub-self"; "(- ?a ?a)" => "0"),
        rewrite!("reassoc-add"; "(+ (+ ?x ?c1) ?c2)" => "(+ ?x (+ ?c1 ?c2))"
                 if both_const("?c1", "?c2")),
        rewrite!("sub-const"; "(- ?x ?c)" => "(+ ?x (- 0 ?c))" if is_const("?c")),
    ]
}

fn main() {
    let path = std::env::args().nth(1).expect("program file");
    let text = std::fs::read_to_string(path).unwrap();
    let mut lines = text.lines().peekable();
    let rules = rules();
    let out_path = std::env::args().nth(2).expect("output file for the extracted programs");
    let mut dumped = String::new();
    let mut extracted_nodes = 0usize;
    let mut total = 0.0f64;
    let (mut programs, mut iters_sum, mut nodes_sum, mut classes_sum) = (0usize, 0usize, 0usize, 0usize);
    while let Some(header) = lines.next() {
        let mut h = header.split_whitespace();
        let _name = h.next().unwrap();
        let n: usize = h.next().unwrap().parse().unwrap();
        let start = Instant::now();
        let mut eg: EGraph<Arith, ConstFold> = Default::default();
        // values: 0..3 are the parameters, 4..8 the constants 0, 1, 2, -1, 3 (as gen.rb numbers them)
        let mut vals: Vec<Id> = Vec::new();
        for p in ["a", "b", "c", "d"] {
            vals.push(eg.add(Arith::Sym(p.into())));
        }
        for c in [0i64, 1, 2, -1, 3] {
            vals.push(eg.add(Arith::Num(c)));
        }
        let input_nodes_limit = 0usize;
        let _ = input_nodes_limit;
        let mut last = vals[0];
        for _ in 0..n {
            let line = lines.next().unwrap();
            let mut t = line.split_whitespace();
            let op = t.next().unwrap();
            let a: usize = t.next().unwrap().parse().unwrap();
            let b: usize = t.next().unwrap().parse().unwrap();
            let node = match op {
                "+" => Arith::Add([vals[a], vals[b]]),
                "*" => Arith::Mul([vals[a], vals[b]]),
                _ => Arith::Sub([vals[a], vals[b]]),
            };
            last = eg.add(node);
            vals.push(last);
        }
        let input_nodes = eg.total_number_of_nodes();
        let runner = Runner::default()
            .with_egraph(eg)
            .with_iter_limit(8)
            .with_node_limit(input_nodes + 2000)
            .with_time_limit(std::time::Duration::from_secs(60))
            .run(&rules);
        let root = runner.egraph.find(last);
        let (_cost, best) = Extractor::new(&runner.egraph, AstSize).find_best(root);
        // the extracted program as a DAG: one line per node, children before parents; the last line is the root
        let mut dump = format!("f{} {}\n", programs, best.as_ref().len());
        for node in best.as_ref() {
            let line = match node {
                Arith::Num(n) => format!("num {}", n),
                Arith::Sym(s) => format!("sym {}", s),
                Arith::Add([a, b]) => format!("+ {} {}", usize::from(*a), usize::from(*b)),
                Arith::Mul([a, b]) => format!("* {} {}", usize::from(*a), usize::from(*b)),
                Arith::Sub([a, b]) => format!("- {} {}", usize::from(*a), usize::from(*b)),
            };
            dump.push_str(&line);
            dump.push('\n');
        }
        dumped.push_str(&dump);
        extracted_nodes += best.as_ref().len();
        total += start.elapsed().as_secs_f64();
        programs += 1;
        iters_sum += runner.iterations.len();
        nodes_sum += runner.egraph.total_number_of_nodes();
        classes_sum += runner.egraph.number_of_classes();
    }
    std::fs::write(&out_path, &dumped).unwrap();
    println!("egg extracted (DAG) nodes: {:.1} per program", extracted_nodes as f64 / programs as f64);
    println!(
        "egg: {} programs, {:.3} s total ({:.1} ms each), avg {:.0} iterations, {:.0} e-nodes, {:.0} classes",
        programs,
        total,
        1000.0 * total / programs as f64,
        iters_sum as f64 / programs as f64,
        nodes_sum as f64 / programs as f64,
        classes_sum as f64 / programs as f64
    );
}
