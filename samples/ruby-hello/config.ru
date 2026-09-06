require "json"

BODY = JSON.generate(
  message: "Hallo von Ruby auf Korifi",
  buildpack: "paketo-buildpacks/ruby",
  vcap_services_present: !ENV["VCAP_SERVICES"].nil?
)

run lambda { |env|
  body = if env["PATH_INFO"] == "/env"
           JSON.generate(vcap_services: ENV.fetch("VCAP_SERVICES", "<leer>"))
         else
           BODY
         end
  [200, { "content-type" => "application/json" }, [body]]
}
