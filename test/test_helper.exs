contract_dir = Path.expand("../../../sdks/contract", __DIR__)

if File.dir?(contract_dir) and is_nil(System.get_env("ALPLUS_CONTRACT_DIR")) do
  System.put_env("ALPLUS_CONTRACT_DIR", contract_dir)
end

ExUnit.start()
