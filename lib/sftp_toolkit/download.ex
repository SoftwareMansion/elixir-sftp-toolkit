defmodule SFTPToolkit.Download do
  @moduledoc """
  Module containing functions that ease downloading data from the SFTP server.
  """

  use Bunch

  @default_operation_timeout 5000
  @default_chunk_size 32768
  @default_remote_mode [:read, :binary]
  @default_local_mode [:write, :binary]

  @doc """
  Downloads a single file by reading it in chunks to avoid loading whole
  file into memory as `:ssh_sftp.read_file/3` does by default.

  ## Arguments

  Expects the following arguments:

  * `sftp_channel_pid` - PID of the already opened SFTP channel,
  * `remote_path` - remote path to the file on the SFTP server,
  * `local_path` - local path to the file,
  * `options` - additional options, see below.

  ## Options

  * `operation_timeout` - SFTP operation timeout (it is a timeout
    per each SFTP operation, not total timeout), defaults to 5000 ms,
  * `chunk_size` - chunk size in bytes, defaults to 32KB,
  * `remote_mode` - mode used while opening the remote file, defaults
    to `[:read, :binary]`, see `:ssh_sftp.open/3` for possible
    values,
  * `local_mode` - mode used while opening the local file, defaults
    to `[:write, :binary]`, see `File.open/2` for possible
    values.

  ## Return values

  On success returns `:ok`.

  On error returns `{:error, reason}`, where `reason` might be one
  of the following:

  * `{:local_open, info}` - the `File.open/2` on the local file failed,
  * `{:remote_open, info}` - the `:ssh_sftp.open/4` on the remote file
    failed,
  * `{:download, {:read, info}}` - the `IO.binwrite/2` on the local file
    failed,
  * `{:download, {:write, info}}` - the `:ssh_sftp.read/4` on the remote
    file failed,
  * `{:local_close, info}` - the `File.close/1` on the local file failed,
  * `{:remote_close, info}` - the `:ssh_sftp.close/2` on the remote file
    failed.
  """
  @spec download_file(pid, Path.t(), Path.t(),
          operation_timeout: timeout,
          chunk_size: pos_integer,
          remote_mode: [:read | :write | :creat | :trunc | :append | :binary],
          local_mode: [File.mode()]
        ) :: :ok | {:error, any}
  def download_file(sftp_channel_pid, remote_path, local_path, options \\ []) do
    chunk_size = Keyword.get(options, :chunk_size, @default_chunk_size)
    operation_timeout = Keyword.get(options, :operation_timeout, @default_operation_timeout)
    remote_mode = Keyword.get(options, :remote_mode, @default_remote_mode)
    local_mode = Keyword.get(options, :local_mode, @default_local_mode)

    withl remote_open:
            {:ok, remote_handle} <-
              :ssh_sftp.open(sftp_channel_pid, remote_path, remote_mode, operation_timeout),
          local_open: {:ok, local_handle} <- File.open(local_path, local_mode),
          download:
            :ok <-
              do_download_file(
                sftp_channel_pid,
                local_handle,
                remote_handle,
                chunk_size,
                operation_timeout
              ),
          remote_close:
            :ok <- :ssh_sftp.close(sftp_channel_pid, remote_handle, operation_timeout),
          local_close: :ok <- File.close(local_handle) do
      :ok
    else
      local_open: {:error, reason} -> {:error, {:local_open, reason}}
      remote_open: {:error, reason} -> {:error, {:remote_open, reason}}
      download: {:error, reason} -> {:error, {:download, reason}}
      remote_close: {:error, reason} -> {:error, {:remote_close, reason}}
      local_close: {:error, reason} -> {:error, {:local_close, reason}}
    end
  end

  defp do_download_file(
         sftp_channel_pid,
         local_handle,
         remote_handle,
         chunk_size,
         operation_timeout
       ) do
    case :ssh_sftp.read(sftp_channel_pid, remote_handle, chunk_size, operation_timeout) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, {:read, reason}}

      {:ok, data} ->
        case IO.binwrite(local_handle, data) do
          :ok ->
            do_download_file(
              sftp_channel_pid,
              local_handle,
              remote_handle,
              chunk_size,
              operation_timeout
            )

          {:error, reason} ->
            {:error, {:write, reason}}
        end
    end
  end
end
