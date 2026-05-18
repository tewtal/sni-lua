use std::env;

fn main() {
    // Use the prebuilt protoc shipped by `protoc-bin-vendored` so the build
    // does not depend on a system-installed protoc (important on Windows).
    let protoc = protoc_bin_vendored::protoc_bin_path().expect("vendored protoc");
    env::set_var("PROTOC", protoc);

    // The SNI proto has no `package`, so tonic-build emits the code for the
    // empty/default package. We point OUT_DIR at a known file and `include!`
    // it from a hand-declared `pb` module in lib.rs (instead of the
    // package-name-based `tonic::include_proto!`).
    tonic_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&["../../proto/sni.proto"], &["../../proto"])
        .expect("failed to compile sni.proto");

    println!("cargo:rerun-if-changed=../../proto/sni.proto");
}
