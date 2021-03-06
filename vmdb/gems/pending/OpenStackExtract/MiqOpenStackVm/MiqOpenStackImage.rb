require 'util/miq_tempfile'
require_relative '../../MiqVm/MiqVm'

class MiqOpenStackImage
  attr_reader :vmConfigFile

  SUPPORTED_METHODS = [:rootTrees, :extract, :diskInitErrors]

  def initialize(image_id, args)
    @image_id     = image_id
    @os_handle    = args[:os_handle]
    @args         = args
    @vmConfigFile = image_id

    raise ArgumentError, "#{self.class.name}: required arg os_handle missing"    unless @os_handle
    @fog_image    = @os_handle.detect_image_service
    raise ArgumentError, "#{self.class.name}: required arg fog_image missing"    unless @fog_image
  end

  def unmount
    return unless @miq_vm
    @miq_vm.unmount
    @temp_image_file.unlink
  end

  private

  def miq_vm
    @miq_vm ||= begin
      @temp_image_file = get_image_file
      hardware  = "scsi0:0.present = \"TRUE\"\n"
      hardware += "scsi0:0.filename = \"#{@temp_image_file.path}\"\n"

      diskFormat = @fog_image.get_image(@image_id).headers['X-Image-Meta-Disk_format']
      $log.debug "diskFormat = #{diskFormat}"

      ost = OpenStruct.new
      ost.rawDisk = diskFormat == "raw"
      MiqVm.new(hardware, ost)
    end
  end

  def get_image_file
    log_pref = "#{self.class.name}##{__method__}"

    image = @fog_image.get_image(@image_id)
    raise "Image #{@image_id} not found" unless image

    iname = image.headers['X-Image-Meta-Name']
    isize = image.headers['X-Image-Meta-Size'].to_i
    $log.debug "#{log_pref}: iname = #{iname}"
    $log.debug "#{log_pref}: isize = #{isize}"

    raise "Image: #{iname} (#{@image_id}) is empty" unless isize > 0

    tot = 0
    rv = nil

    tf = MiqTempfile.new(iname, :encoding => 'ascii-8bit')
    $log.debug "#{log_pref}: saving image to #{tf.path}"
    response_block = lambda do |buf, _rem, sz|
      tf.write buf
      tot += buf.length
      $log.debug "#{log_pref}: response_block: #{tot} bytes written of #{sz}"
    end

    #
    # We're calling the low-level request method here, because
    # the Fog "get image" methods don't currently support passing
    # a response block. We should attempt to remedy this in Fog
    # upstream and modify this code accordingly.
    #
    rv = @fog_image.request(
      :expects        => [200, 204],
      :method         => 'GET',
      :path           => "images/#{@image_id}",
      :response_block => response_block
    )

    tf.close

    checksum = rv.headers['X-Image-Meta-Checksum']
    $log.debug "#{log_pref}: Checksum: #{checksum}" if $log.debug?
    $log.debug "#{log_pref}: #{`ls -l #{tf.path}`}" if $log.debug?

    if tf.size != isize
      $log.error "#{log_pref}: Error downloading image #{iname}"
      $log.error "#{log_pref}: Downloaded size does not match image size #{tf.size} != #{isize}"
      raise "Image download failed"
    end

    tf
  end

  def method_missing(sym, *args)
    super unless SUPPORTED_METHODS.include? sym
    return miq_vm.send(sym) if args.empty?
    miq_vm.send(sym, args)
  end

  def respond_to_missing?(sym, *args)
    if SUPPORTED_METHODS.include?(sym)
      true
    else
      super
    end
  end
end
