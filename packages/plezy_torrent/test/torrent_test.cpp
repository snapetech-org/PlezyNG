#include "../src/plezy_torrent.h"
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/hasher.hpp>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;
void verify_transfer(bool multiple_files, bool v2 = false, bool large = false) {
  std::cout << "transfer multiple_files=" << multiple_files << " v2=" << v2
            << " large=" << large << std::endl;
  assert(pt_abi_version() == 1);
  assert(pt_open("invalid", "/tmp", -1, 1LL << 26, 16384) == nullptr);
  const auto root = fs::temp_directory_path() / ("plezy-p2p-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(root / "seed"); fs::create_directories(root / "read");
  // Exercise 64-bit media sizes and reads beyond 4 GiB without allocating or
  // hashing 4 GiB. The sparse prefix is zero; the final piece has real bytes.
  const int64_t prefix_size = large ? 1LL << 32 : 0;
  std::vector<char> data(large ? 271 : 2 * 1024 * 1024 + 271);
  const int64_t media_size = prefix_size + data.size();
  for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<char>((i * 31 + i / 251) % 256);
  fs::create_directories(root / "seed" / "pack");
  // A v2 single-file torrent has no enclosing directory in its file tree.
  // Write exactly the path advertised by the fixture for both versions.
  const auto media_path = multiple_files ? "pack/fixture.mp4" : "fixture.mp4";
  std::ofstream out(root / "seed" / media_path, std::ios::binary);
  out.seekp(prefix_size);
  out.write(data.data(), data.size()); out.close();
  lt::file_storage files;
  if (multiple_files) {
    // Selected media starts in the middle of a piece; adjacent files must
    // never leak into the player's zero-based range address space.
    std::ofstream prefix(root / "seed" / "pack" / "readme.txt", std::ios::binary);
    std::string padding(12345, 'x'); prefix << padding; prefix.close();
    files.add_file("pack/readme.txt", padding.size());
  }
  files.add_file(media_path, media_size);
  const int piece_size = large ? 1024 * 1024 : 16 * 1024;
  lt::create_torrent create(files, piece_size, v2 ? lt::create_torrent::v2_only : lt::create_torrent::v1_only);
  if (large) {
    assert(!multiple_files && !v2);
    const std::vector<char> zeros(piece_size, 0);
    const auto zero_hash = lt::hasher(zeros.data(), zeros.size()).final();
    for (int i = 0; i < create.num_pieces() - 1; ++i) create.set_hash(lt::piece_index_t(i), zero_hash);
    create.set_hash(lt::piece_index_t(create.num_pieces() - 1), lt::hasher(data.data(), data.size()).final());
  } else {
    lt::set_piece_hashes(create, (root / "seed").string());
  }
  auto metadata = std::make_shared<lt::torrent_info>(create.generate());
  lt::settings_pack settings;
  settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
  settings.set_bool(lt::settings_pack::enable_dht, false);
  settings.set_bool(lt::settings_pack::enable_lsd, false);
  settings.set_bool(lt::settings_pack::enable_ip_notifier, false);
  settings.set_bool(lt::settings_pack::enable_upnp, false);
  settings.set_bool(lt::settings_pack::enable_natpmp, false);
  settings.set_int(lt::settings_pack::alert_mask, lt::alert_category::all);
  if (large) settings.set_int(lt::settings_pack::upload_rate_limit, 16 * 1024 * 1024);
  lt::session seed{lt::session_params{settings}};
  lt::add_torrent_params params;
  params.ti = metadata; params.save_path = (root / "seed").string();
  params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
  params.flags |= lt::torrent_flags::seed_mode;
  auto source = seed.add_torrent(params);
  for (int n = 0; seed.listen_port() == 0 && n < 100; ++n) std::this_thread::sleep_for(50ms);
  const auto magnet = lt::make_magnet_uri(source) + "&x.pe=127.0.0.1:" + std::to_string(seed.listen_port());
  const auto parsed = lt::parse_magnet_uri(magnet);
  assert(!parsed.peers.empty());
  assert(v2 ? parsed.info_hashes.has_v2() : parsed.info_hashes.has_v1());
  void* stream = pt_open(magnet.c_str(), (root / "read").string().c_str(), multiple_files ? 1 : -1,
                         large ? 6LL << 30 : 1LL << 26, 16384);
  assert(stream);
  auto deadline = std::chrono::steady_clock::now() + 40s;
  int64_t size = -2;
  while (size == -2 && std::chrono::steady_clock::now() < deadline) { size = pt_size(stream); std::this_thread::sleep_for(50ms); }
  if (size != media_size) {
    std::vector<lt::alert*> alerts; seed.pop_alerts(&alerts); for (auto* alert : alerts) std::cerr << alert->message() << std::endl;
    auto status = source.status();
    std::cerr << "size=" << size << " seed peers=" << status.num_peers << " error=" << status.errc.message() << " port=" << seed.listen_port() << std::endl;
  }
  assert(size == media_size);
  char name[256]; assert(pt_name(stream, name, sizeof(name)) > 0); assert(std::string(name) == "fixture.mp4");
  std::vector<uint8_t> buffer(64 * 1024);
  // Tail first, then cross a piece boundary, then seek backwards.
  for (int64_t position : {size - 100, large ? prefix_size - 100 : int64_t(16380), int64_t(0), size / 2}) {
    const auto end = std::min<int64_t>(position + buffer.size(), size);
    while (position < end) {
      int read = -2;
      deadline = std::chrono::steady_clock::now() + 40s;
      while (read == -2 && std::chrono::steady_clock::now() < deadline) {
        read = pt_read(stream, position, buffer.data(), end - position); std::this_thread::sleep_for(50ms);
      }
      if (read <= 0) {
        std::vector<lt::alert*> alerts;
        seed.pop_alerts(&alerts);
        for (auto* alert : alerts) std::cerr << alert->message() << std::endl;
        const auto status = source.status();
        std::cerr << "read=" << read << " position=" << position
                  << " size=" << size << " seed peers=" << status.num_peers
                  << " uploaded=" << status.total_payload_upload
                  << " error=" << status.errc.message() << std::endl;
      }
      assert(read > 0);
      for (int i = 0; i < read; ++i) {
        const int64_t source_position = position + i;
        const auto expected = source_position < prefix_size ? uint8_t(0)
            : static_cast<uint8_t>(data[source_position - prefix_size]);
        assert(buffer[i] == expected);
      }
      position += read;
    }
  }
  assert(pt_read(stream, size, buffer.data(), buffer.size()) == 0);
  assert(pt_read(stream, -1, buffer.data(), buffer.size()) == -1);
  pt_close(stream);
  seed.remove_torrent(source);
  fs::remove_all(root);
}
int main() {
  verify_transfer(false);
  verify_transfer(true);
  verify_transfer(false, true);
  verify_transfer(false, false, true);
  std::cout << "verified single/multi-file and >4 GiB transfer, metadata, seeking, EOF and invalid input passed\n";
}
