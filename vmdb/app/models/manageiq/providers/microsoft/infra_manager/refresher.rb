# TODO: is this required?  never seemed to be used anywhere
$LOAD_PATH << File.join(GEMS_PENDING_ROOT, "Scvmm")
require 'MiqScvmmInventory'

module ManageIQ::Providers::Microsoft
  class InfraManager::Refresher < EmsRefresh::Refreshers::BaseRefresher
    include EmsRefresh::Refreshers::EmsRefresherMixin

    def parse_inventory(ems, _targets)
      ManageIQ::Providers::Microsoft::InfraManager::RefreshParser.ems_inv_to_hashes(ems, refresher_options)
    end

    def post_process_refresh_classes
      # TODO: previously this only looped over VM classes, but, since SCVMM is
      # infra, it should probably include Host, too
      [::Vm]
    end
  end
end
