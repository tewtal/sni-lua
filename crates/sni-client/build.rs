use std::env;

fn main() {
    // Use the prebuilt protoc shipped by `protoc-bin-vendored` so the build
    // does not depend on a system-installed protoc (important on Windows).
    let protoc = protoc_bin_vendored::protoc_bin_path().expect("vendored protoc");
    env::set_var("PROTOC", protoc);

    tonic_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&["../../proto/sni.proto"], &["../../proto"])
        .expect("failed to compile sni.proto");

    println!("cargo:rerun-if-changed=../../proto/sni.proto");
}
