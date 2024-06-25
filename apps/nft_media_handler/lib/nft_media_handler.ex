defmodule NFTMediaHandler do
  @moduledoc """
  Module resizes and uploads images to R2/S3 bucket.
  """

  require Logger

  alias Image.Video
  alias NFTMediaHandler.Media.Fetcher
  alias NFTMediaHandler.Image.Resizer
  alias NFTMediaHandler.R2.Uploader

  @spec prepare_media_and_upload(binary() | File.Stream.t(), any()) :: map()
  def prepare_media_and_upload(file_path, file_name) do
    {:ok, image} = Image.open(file_path)

    thumbnails = Resizer.resize(file_path, image) |> dbg()

    uploaded_thumbnails =
      Enum.map(thumbnails, fn {size, image} ->
        with {:ok, _result, uploaded_file_url} <- Uploader.upload_image(image, generate_file_name(file_name, size)) do
          {size, uploaded_file_url}
        else
          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.into(%{})

    uploaded_original_url =
      with {:ok, binary} <- File.read(file_path),
           {:ok, _result, uploaded_file_url} <- Uploader.upload_image(binary, generate_file_name(file_name)) do
        uploaded_file_url
      else
        _ ->
          nil
      end

    max_size_or_original =
      uploaded_original_url ||
        (
          {_, url} =
            Enum.max_by(uploaded_thumbnails, fn {size, _} ->
              {int_size, _} = Integer.parse(size)
              int_size
            end)

          url
        )

    Enum.reduce(Resizer.sizes(), uploaded_thumbnails, fn {_, size}, acc ->
      if Map.has_key?(acc, size) do
        acc
      else
        Map.put(acc, size, max_size_or_original)
      end
    end)
    |> Map.put("original", uploaded_original_url)
  end

  def prepare_and_upload_by_url(url) do
    with {:ok, media_type, body} <- Fetcher.fetch_media(url) do
      prepare_and_upload_inner(media_type, body, url)
    else
      {:error, reason} ->
        Logger.warning("Error on fetching media from url (#{url}): #{inspect(reason)}")
        :error
    end
  end

  def prepare_and_upload_inner({"image", _} = media_type, body, url) do
    with {:image, {:ok, image}} <- {:image, Image.from_binary(body)} do
      extension = media_type_to_extension(media_type)

      thumbnails = Resizer.resize("../../images/", image, url, ".#{extension}") |> dbg()

      uploaded_thumbnails =
        Enum.map(thumbnails, fn {size, image, file_name} ->
          # generate_file_name(file_name, size)
          with {:ok, _result, uploaded_file_url} <- Uploader.upload_image(image, file_name) do
            {size, uploaded_file_url}
          else
            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.into(%{})

      #  {:ok, binary} <- File.read(file_path),

      uploaded_original_url =
        with {:ok, _result, uploaded_file_url} <-
               Uploader.upload_image(body, Resizer.generate_file_name(url, ".#{extension}", "original")) do
          uploaded_file_url
        else
          _ ->
            nil
        end

      max_size_or_original =
        uploaded_original_url ||
          (
            {_, url} =
              Enum.max_by(uploaded_thumbnails, fn {size, _} ->
                {int_size, _} = Integer.parse(size)
                int_size
              end)

            url
          )

      Enum.reduce(Resizer.sizes(), uploaded_thumbnails, fn {_, size}, acc ->
        if Map.has_key?(acc, size) do
          acc
        else
          Map.put(acc, size, max_size_or_original)
        end
      end)
      |> Map.put("original", uploaded_original_url)
    else
      {:image, {:error, reason}} ->
        Logger.warning("Error on open image from url (#{url}): #{inspect(reason)}")
        :error
    end
  end

  def prepare_and_upload_inner({"video", _} = media_type, body, url) do
    extension = media_type_to_extension(media_type)
    file_name = Resizer.generate_file_name(url, ".jpg", "original")
    path = "../../images/#{file_name}"

    with :ok <- File.write(path, body),
         {:ok, video} = Video.open(path),
         {:ok, image} <- Video.image_from_video(video, frame: 0) do
      thumbnails = Resizer.resize("../../images/", image, url, ".jpg")

      uploaded_thumbnails =
        Enum.map(thumbnails, fn {size, image, file_name} ->
          # generate_file_name(file_name, size)
          with {:ok, _result, uploaded_file_url} <- Uploader.upload_image(image, file_name) do
            {size, uploaded_file_url}
          else
            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.into(%{})
    end
  end

  defp media_type_to_extension({type, subtype}) do
    [extension | _] = MIME.extensions("#{type}/#{subtype}")
    extension
  end

  defp generate_file_name(image_name, size \\ "original") do
    "#{image_name}_#{size}.jpg"
  end
end