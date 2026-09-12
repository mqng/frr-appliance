umask 027

# ip, nft and the appliance tools are in sbin
case ":$PATH:" in
  *:/usr/local/sbin:*) ;;
  *) PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"; export PATH ;;
esac
