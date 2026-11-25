defmodule LoadExamples do
  @pattern "examples/hayata_*_example.ex"

  def load do
    case Path.wildcard(@pattern) |> Enum.sort() do
      [] ->
        {:error, {:no_files_found, Path.expand(@pattern)}}

      files ->
        Enum.reduce_while(files, {:ok, []}, &load_file/2)
    end
  end

  defp load_file(file, {:ok, acc}) do
    # compile_file/1 siempre carga y devuelve [{NombreModulo, binario}]
    loaded_modules =
      file
      |> Code.compile_file()
      |> Enum.map(fn {mod, _bin} -> mod end)

    {:cont, {:ok, acc ++ loaded_modules}}
  rescue
    error ->
      {:halt, {:error, {:load_failed, file, error}}}
  end
end
